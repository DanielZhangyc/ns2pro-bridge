import AppKit
import SwiftUI
import NS2Transport

private final class CallbackContext: Sendable {
    let session: UInt64
    init(_ session: UInt64) { self.session = session }
}

private let inputCallback: ns2_state_callback = { state, context in
    guard let state, let context else { return }
    let session = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue().session
    let buttons = state.pointee.buttons
    let lx = state.pointee.lx, ly = state.pointee.ly, rx = state.pointee.rx, ry = state.pointee.ry
    Task { @MainActor in
        await BridgeModel.shared.publish(session: session, buttons: buttons, lx: lx, ly: ly, rx: rx, ry: ry)
    }
}

private let statusCallback: ns2_status_callback = { status, message, context in
    guard let context else { return }
    let session = Unmanaged<CallbackContext>.fromOpaque(context).takeUnretainedValue().session
    let value = status.rawValue
    let text = message.map { String(cString: $0) } ?? ""
    Task { @MainActor in BridgeModel.shared.receiveStatus(session: session, value: value, message: text) }
}

@MainActor final class BridgeModel: ObservableObject {
    static let shared = BridgeModel()
    @Published var status = "尚未连接"
    @Published var detail = "结束当前游戏并退出其他适配器后，点击连接，再长按手柄顶部 SYNC。"
    @Published var running = false
    @Published var busy = false
    @Published var gain = 2.0
    @Published var nativeEnabled = true
    @Published private(set) var ready = false
    @Published private(set) var deviceName = "Nintendo Switch 2 Pro"
    @Published private(set) var deviceIdentifier = "未连接"
    @Published private(set) var batteryMillivolts: Int?
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var externalPower: Bool?
    @Published private(set) var telemetryError = ""
    @Published private(set) var charging: Bool?
    @Published private(set) var signalStrength: Int?
    @Published private(set) var buttons: UInt64 = 0
    @Published private(set) var axes = [Double](repeating: 0, count: 4)
    @Published private(set) var connectedSince: Date?
    private var lastInputDisplay = 0.0
    private var lastInfoDisplay = 0.0
    let provisioned = Bundle.main.object(forInfoDictionaryKey: "NS2VirtualHIDProvisioned") as? Bool == true
    private init() {
        if !provisioned {
            status = "缺少系统手柄授权"
            detail = "此构建尚无 Apple Virtual HID 授权，无法连接为系统手柄。需要匹配的描述文件和正式签名；重新允许蓝牙不能解决。"
        }
    }
    private var session: UInt64 = 0
    private var callbackContext: CallbackContext?
    private var timer: Timer?
    private var nativeUntil: ContinuousClock.Instant?
    private var rumbleUntil: ContinuousClock.Instant?
    private var rumbleRevision: UInt64 = 0
    private lazy var virtual = VirtualController { [weak self] left, right, duration in
        await self?.ordinaryRumble(left: left, right: right, duration: duration)
    }
    private lazy var native = NativeHapticsServer(onFrame: { [weak self] frame in
        self?.nativeRumble(frame)
    }, onError: { [weak self] message in
        ns2_stop_rumble()
        self?.detail = message
    })

    func connect() async {
        guard provisioned, !running, !busy else { return }
        busy = true
        defer { busy = false }
        session &+= 1
        status = "正在准备虚拟手柄"
        do {
            await virtual.setRumbleSuppressed(true)
            try await virtual.start()
            if nativeEnabled { try native.start() }
            setenv("NS2PRO_RUMBLE_GAIN", String(gain), 1)
            let context = CallbackContext(session)
            callbackContext = context
            guard ns2_start(inputCallback, statusCallback, Unmanaged.passUnretained(context).toOpaque()) == 1 else {
                throw NativeHapticsError.system("启动蓝牙适配失败", EIO)
            }
            running = true
            status = "正在搜索手柄"
            detail = "长按手柄顶部 SYNC，直到玩家灯闪烁。"
            let expiryTimer = Timer(timeInterval: 0.025, repeats: true) { _ in
                MainActor.assumeIsolated { BridgeModel.shared.expireRumble() }
            }
            RunLoop.main.add(expiryTimer, forMode: .common)
            timer = expiryTimer
        } catch {
            native.stop()
            await virtual.stop()
            callbackContext = nil
            status = "连接失败"
            detail = error.localizedDescription
        }
    }

    func disconnect() async {
        while busy {
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { detail = error.localizedDescription; return }
        }
        busy = true
        session &+= 1
        ready = false
        clearDeviceInfo()
        running = false
        timer?.invalidate()
        timer = nil
        nativeUntil = nil
        rumbleUntil = nil
        rumbleRevision &+= 1
        native.stop()
        ns2_stop_rumble()
        let stopped = ns2_shutdown("用户断开 / user disconnect", 350)
        callbackContext = nil
        await virtual.stop()
        status = "已断开"
        detail = stopped == 1 ? "手柄已释放，可以连接其他应用。" : "已关闭连接，但停止震动报文未确认提交。"
        busy = false
    }

    fileprivate func receiveStatus(session: UInt64, value: UInt32, message: String) {
        guard session == self.session, running else { return }
        let wasReady = ready
        ready = value == NS2_STATUS_READY.rawValue
        if ready && !wasReady {
            connectedSince = Date()
            refreshDeviceInfo()
            Task {
                guard session == self.session, self.ready else { return }
                await virtual.setRumbleSuppressed(false)
            }
        }
        switch value {
        case NS2_STATUS_READY.rawValue: status = "手柄已连接"; detail = "玩家灯应常亮。支持系统手柄输入、普通震动和双频接口。"
        case NS2_STATUS_SCANNING.rawValue: status = "正在搜索手柄"
        case NS2_STATUS_CONNECTING.rawValue: status = "正在连接手柄"
        case NS2_STATUS_INITIALIZING.rawValue: status = "正在初始化手柄"
        case NS2_STATUS_DISCONNECTED.rawValue: status = "连接已中断"; detail = "按手柄按键唤醒，或长按 SYNC 重新连接。"
        case NS2_STATUS_ERROR.rawValue, NS2_STATUS_UNAVAILABLE.rawValue: status = "手柄暂不可用"; detail = message
        default: break
        }
        if wasReady && !ready {
            clearDeviceInfo()
            nativeUntil = nil
            rumbleUntil = nil
            rumbleRevision &+= 1
            ns2_stop_rumble()
            Task {
                guard session == self.session, !self.ready else { return }
                await virtual.setRumbleSuppressed(true)
                await publishNeutral(session: session)
            }
        }
    }

    fileprivate func publish(session: UInt64, buttons: UInt64, lx: Int32, ly: Int32, rx: Int32, ry: Int32) async {
        guard session == self.session, ready else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if buttons != self.buttons || now - lastInputDisplay >= 1.0 / 30 {
            self.buttons = buttons
            axes = [lx, ly, rx, ry].map { Double($0) / 32767 }
            lastInputDisplay = now
        }
        do { try await virtual.publish(buttons: buttons, lx: lx, ly: ly, rx: rx, ry: ry) }
        catch { if session == self.session { await outputFailed(error) } }
    }

    private func publishNeutral(session: UInt64) async {
        guard session == self.session, running, !ready else { return }
        do { try await virtual.publish(buttons: 0, lx: 0, ly: 0, rx: 0, ry: 0) }
        catch { if session == self.session { await outputFailed(error) } }
    }

    private func outputFailed(_ error: Error) async {
        await disconnect()
        status = "虚拟手柄输出失败"
        detail = error.localizedDescription
    }

    private func ordinaryRumble(left: Double, right: Double, duration: Double) {
        guard ready else { return }
        guard nativeUntil == nil else { return }
        guard duration > 0, left > 0 || right > 0 else {
            rumbleUntil = nil
            ns2_stop_rumble()
            return
        }
        // 普通接口没有载频；固定载频仅用于兼容，不能重建原始 HD 波形。
        // Ordinary rumble has no carriers; fixed carriers provide compatibility, not original HD waveforms.
        let lease = min(duration + 0.15, 1)
        ns2_send_lease(0, Float(left), 160, 0, 320, UInt32(lease * 1000))
        ns2_send_lease(1, 0, 160, Float(right), 320, UInt32(lease * 1000))
        rumbleUntil = .now.advanced(by: .seconds(lease))
    }

    private func nativeRumble(_ frame: HapticFrame) {
        guard ready else { return }
        rumbleRevision &+= 1
        let revision = rumbleRevision
        if frame.durationMilliseconds == 0 {
            nativeUntil = nil
            rumbleUntil = nil
            ns2_stop_rumble()
            Task {
                await virtual.setRumbleSuppressed(true)
                guard revision == rumbleRevision, ready else { return }
                await virtual.setRumbleSuppressed(false)
            }
            return
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(frame.durationMilliseconds))
        nativeUntil = deadline
        rumbleUntil = deadline
        Task {
            await virtual.setRumbleSuppressed(true)
            guard revision == rumbleRevision, ready, ContinuousClock.now < deadline else { return }
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let milliseconds = UInt32(max(0, remaining.seconds * 1000 + remaining.attoseconds / 1_000_000_000_000_000))
            for (index, band) in [frame.left, frame.right].enumerated() {
                ns2_send_lease(UInt32(index), band.lowAmplitude, band.lowFrequency, band.highAmplitude, band.highFrequency, milliseconds)
            }
        }
    }

    private func expireRumble() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastInfoDisplay >= 0.25 {
            refreshDeviceInfo()
            lastInfoDisplay = now
        }
        if let rumbleUntil, ContinuousClock.now >= rumbleUntil {
            self.rumbleUntil = nil
            nativeUntil = nil
            ns2_stop_rumble()
            let revision = rumbleRevision
            Task {
                guard revision == rumbleRevision, ready else { return }
                await virtual.setRumbleSuppressed(false)
            }
        }
    }

    private func refreshDeviceInfo() {
        var info = ns2_info()
        ns2_get_info(&info)
        deviceName = withUnsafeBytes(of: info.name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        if deviceName.isEmpty { deviceName = "Nintendo Switch 2 Pro" }
        deviceIdentifier = withUnsafeBytes(of: info.identifier) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        if deviceIdentifier.isEmpty { deviceIdentifier = "未连接" }
        batteryMillivolts = info.battery_known != 0 ? Int(info.battery_millivolts) : nil
        batteryLevel = info.battery_level_known != 0 ? Int(info.battery_level) : nil
        externalPower = info.external_power_known != 0 ? info.external_power != 0 : nil
        telemetryError = withUnsafeBytes(of: info.telemetry_error) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        charging = info.charging_known != 0 ? info.charging != 0 : nil
        signalStrength = info.rssi_known != 0 ? Int(info.rssi_dbm) : nil
    }

    private func clearDeviceInfo() {
        batteryMillivolts = nil
        batteryLevel = nil
        externalPower = nil
        telemetryError = ""
        charging = nil
        signalStrength = nil
        connectedSince = nil
        buttons = 0
        axes = [Double](repeating: 0, count: 4)
        deviceIdentifier = "未连接"
    }

    func testRumble() {
        guard ready else { return }
        let band = HapticBand(lowAmplitude: 0.12, lowFrequency: 160, highAmplitude: 0.08, highFrequency: 320)
        nativeRumble(HapticFrame(version: 1, durationMilliseconds: 300, left: band, right: band))
    }

}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mayQuit = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
    }
    @objc private func sleep() { Task { await BridgeModel.shared.disconnect() } }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if mayQuit { return .terminateNow }
        Task {
            await BridgeModel.shared.disconnect()
            mayQuit = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main struct NS2ProBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = BridgeModel.shared
    var body: some Scene {
        Window("NS2 Pro Bridge", id: "controller") {
            ControllerDetailView(model: model)
        }
        .defaultSize(width: 560, height: 650)
        .windowResizability(.contentMinSize)
        Settings { BridgeSettingsView(model: model) }
        MenuBarExtra("NS2 Pro Bridge", systemImage: model.running ? "gamecontroller.fill" : "gamecontroller") {
            ControllerWindowButton()
            Divider()
            Text(model.status).font(.headline)
            Text(model.detail).font(.caption)
            Divider()
            if model.running {
                Button("断开手柄") { Task { await model.disconnect() } }.disabled(model.busy)
            } else {
                Button("连接手柄") { Task { await model.connect() } }.disabled(model.busy || !model.provisioned)
            }
            SettingsLink { Text("设置…") }
            Divider()
            Button("退出 NS2 Pro Bridge") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
