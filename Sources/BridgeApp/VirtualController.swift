import CoreHID
import Foundation
import IOKit.hidsystem

@available(macOS 26.0, *)
actor VirtualController {
    enum State: Sendable, Equatable {
        case stopped, starting, running, stopping
        case failed(String)
    }

    enum BridgeError: LocalizedError {
        case creationFailed, notRunning, lifecycleChanged

        var errorDescription: String? {
            switch self {
            case .creationFailed:
                return L10n.text("Could not create the CoreHID virtual controller. Check Input Monitoring access and the app signature.")
            case .notRunning:
                return L10n.text("The virtual controller is not running.")
            case .lifecycleChanged:
                return L10n.text("The session stopped while the virtual controller was starting.")
            }
        }
    }

    private(set) var state: State = .stopped
    private(set) var lastError: String?
    private let onRumble: @Sendable (Double, Double, Double) async -> Void
    private var device: HIDVirtualDevice?
    private var delegate: Delegate?
    private var generation: UInt64 = 0
    private var rumbleGeneration: UInt64 = 0
    private var rumbleSuppressed = false
    private var rumbleTask: Task<Void, Never>?
    private var motors = [Envelope?](repeating: nil, count: 4)
    private var lastInput = XboxReports.input(buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0)

    init(onRumble: @escaping @Sendable (_ left: Double, _ right: Double, _ duration: Double) async -> Void) {
        self.onRumble = onRumble
    }

    func start() async throws {
        if state == .running { return }
        guard state != .starting, state != .stopping else { throw HIDDeviceError.busy }
        state = .starting
        lastError = nil
        generation &+= 1
        let currentGeneration = generation
        let properties = HIDVirtualDevice.Properties(
            descriptor: XboxReports.descriptor,
            vendorID: 0x045E, productID: 0x0B13,
            transport: .bluetoothLowEnergy,
            product: "Xbox Wireless Controller", manufacturer: "Microsoft",
            versionNumber: 0x050F,
            serialNumber: "NS2ProBridge-XboxBLE-v1"
        )
        guard let created = HIDVirtualDevice(properties: properties) else {
            let error = BridgeError.creationFailed
            record(error)
            state = .failed(error.localizedDescription)
            throw error
        }
        let handler = Delegate(owner: self)
        device = created
        delegate = handler
        await created.activate(delegate: handler)
        guard generation == currentGeneration, device == created else {
            throw BridgeError.lifecycleChanged
        }
        state = .running
        do {
            try await publish(buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0)
        } catch {
            await stop()
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func stop() async {
        guard state != .stopping else { return }
        state = .stopping
        generation &+= 1
        rumbleGeneration &+= 1
        rumbleTask?.cancel()
        rumbleTask = nil
        motors = [Envelope?](repeating: nil, count: 4)
        let previous = device
        device = nil
        delegate = nil
        if let previous {
            // 在 macOS 26 上显式取消底层设备，使所有客户端立即收到断开。
            // Explicitly cancel the underlying device on macOS 26 to disconnect clients.
            if let hid = previous.hidDevice { IOHIDUserDeviceCancel(hid) }
        }
        await onRumble(0, 0, 0)
        state = .stopped
    }

    func publish(buttons: UInt64, lx: Int32, ly: Int32, rx: Int32, ry: Int32) async throws {
        guard state == .running, let device else { throw BridgeError.notRunning }
        let report = XboxReports.input(buttons: buttons, lx: lx, ly: ly, rx: rx, ry: ry)
        do {
            try await device.dispatchInputReport(data: report, timestamp: .now)
            guard self.device == device, state == .running else { throw BridgeError.notRunning }
            lastInput = report
        } catch {
            record(error)
            throw error
        }
    }

    func clearRumble() async {
        rumbleGeneration &+= 1
        rumbleTask?.cancel()
        rumbleTask = nil
        motors = [Envelope?](repeating: nil, count: 4)
        await onRumble(0, 0, 0)
    }

    func setRumbleSuppressed(_ suppressed: Bool) async {
        // 抢占时丢弃旧命令；解除抢占后只接收新报文，不恢复旧包络。
        // Preemption discards old commands; resuming accepts new reports without replaying envelopes.
        rumbleSuppressed = suppressed
        if suppressed { await clearRumble() }
    }

    private func receive(device: HIDVirtualDevice, type: HIDReportType, id: HIDReportID?, data: Data) async throws {
        guard self.device == device, state == .running || state == .starting else {
            throw HIDDeviceError.notReady
        }
        guard type == .output, id == nil || id?.rawValue == 3 else {
            record(HIDDeviceError.unsupported)
            throw HIDDeviceError.unsupported
        }
        let report: XboxReports.Rumble
        do {
            report = try XboxReports.Rumble.decode(reportID: id?.rawValue, data: data)
        } catch {
            record(HIDDeviceError.badArgument)
            throw HIDDeviceError.badArgument
        }
        guard !rumbleSuppressed, report.mask != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for index in 0..<4 where report.mask & (UInt8(1) << (3 - index)) != 0 {
            motors[index] = report.magnitudes[index] == 0 ? nil : Envelope(
                amplitude: report.magnitudes[index], started: now,
                sustain: report.sustain, release: report.release, repeats: report.repeats
            )
        }
        rumbleGeneration &+= 1
        let version = rumbleGeneration
        rumbleTask?.cancel()
        rumbleTask = Task { [weak self] in
            while let interval = await self?.emitRumble(version: version) {
                do { try await Task.sleep(for: .seconds(interval)) }
                catch is CancellationError { return }
                catch { await self?.record(error); return }
            }
        }
    }

    private func emitRumble(version: UInt64) async -> Double? {
        guard version == rumbleGeneration, device != nil, !rumbleSuppressed else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        var values = [Double](repeating: 0, count: 4)
        var interval = 0.08
        var pending = false
        for index in 0..<4 {
            guard let envelope = motors[index] else { continue }
            let sample = envelope.sample(at: now)
            if sample.remaining <= 0 { motors[index] = nil; continue }
            pending = true
            values[index] = sample.amplitude
            interval = min(interval, sample.remaining)
        }
        // 扳机振幅合并到同侧主马达，输出仅是双马达普通震动。
        // Fold trigger amplitudes into the same-side main motor; output is ordinary dual rumble.
        await onRumble(max(values[0], values[2]), max(values[1], values[3]), pending ? interval : 0)
        return pending && version == rumbleGeneration ? max(0.001, interval) : nil
    }

    private func get(device: HIDVirtualDevice, type: HIDReportType, id: HIDReportID?, maxSize: Int) throws -> Data {
        guard self.device == device else { throw HIDDeviceError.notReady }
        guard type == .input, id?.rawValue == 1 else { throw HIDDeviceError.unsupported }
        guard maxSize >= lastInput.count else { throw HIDDeviceError.messageTooLarge }
        return lastInput
    }

    private func record(_ error: any Error) {
        lastError = error.localizedDescription
    }

    private struct Envelope {
        let amplitude: Double
        let started: Double
        let sustain: Double
        let release: Double
        let repeats: Int

        func sample(at now: Double) -> (amplitude: Double, remaining: Double) {
            let elapsed = max(0, now - started)
            // 零时长命令最多保留五秒，必须由宿主续约；有限脉冲遵循 10ms 单位。
            // Zero-duration commands receive a five-second lease; finite pulses use 10 ms units.
            if sustain == 0 { return elapsed < 5 ? (amplitude, 5 - elapsed) : (0, 0) }
            let cycle = sustain + release
            let total = sustain * Double(repeats + 1) + release * Double(repeats)
            guard elapsed < total else { return (0, 0) }
            let phase = elapsed.truncatingRemainder(dividingBy: cycle)
            let active = phase < sustain
            return (active ? amplitude : 0, min(total - elapsed, (active ? sustain : cycle) - phase))
        }
    }

    private final class Delegate: HIDVirtualDeviceDelegate {
        let receive: @Sendable (HIDVirtualDevice, HIDReportType, HIDReportID?, Data) async throws -> Void
        let get: @Sendable (HIDVirtualDevice, HIDReportType, HIDReportID?, Int) async throws -> Data

        init(owner: VirtualController) {
            receive = { [weak owner] device, type, id, data in
                guard let owner else { throw HIDDeviceError.notReady }
                try await owner.receive(device: device, type: type, id: id, data: data)
            }
            get = { [weak owner] device, type, id, maxSize in
                guard let owner else { throw HIDDeviceError.notReady }
                return try await owner.get(device: device, type: type, id: id, maxSize: maxSize)
            }
        }

        func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType,
                              id: HIDReportID?, data: Data) async throws {
            try await receive(device, type, id, data)
        }

        func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType,
                              id: HIDReportID?, maxSize: Int) async throws -> Data {
            return try await get(device, type, id, maxSize)
        }
    }
}
