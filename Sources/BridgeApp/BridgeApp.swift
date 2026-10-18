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
    @Published var status = L10n.text("Not connected")
    @Published var detail = L10n.text("Quit your game and other controller adapters, click Connect, then hold SYNC on top of the controller.")
    @Published var running = false
    @Published var busy = false
    @Published var gain = 2.0
    @Published var nativeEnabled = true
    @Published private(set) var ready = false
    @Published private(set) var deviceName = L10n.text("Nintendo Switch 2 Pro")
    @Published private(set) var deviceIdentifier = L10n.text("Not connected")
    @Published private(set) var batteryMillivolts: Int?
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var externalPower: Bool?
    @Published private(set) var telemetryError = ""
    @Published private(set) var charging: Bool?
    @Published private(set) var signalStrength: Int?
    @Published private(set) var connectedSince: Date?
    let input = ControllerInputModel()
    private var lastInfoDisplay = 0.0
    let provisioned = Bundle.main.object(forInfoDictionaryKey: "NS2VirtualHIDProvisioned") as? Bool == true
    private init() {
        if !provisioned {
            status = L10n.text("System controller authorization missing")
            detail = L10n.text("This build lacks Apple Virtual HID authorization and cannot connect as a system controller. It needs a matching provisioning profile and signing identity; granting Bluetooth access again will not resolve this.")
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
        status = L10n.text("Preparing virtual controller")
        do {
            await virtual.setRumbleSuppressed(true)
            try await virtual.start()
            if nativeEnabled { try native.start() }
            setenv("NS2PRO_RUMBLE_GAIN", String(gain), 1)
            let context = CallbackContext(session)
            callbackContext = context
            guard ns2_start(inputCallback, statusCallback, Unmanaged.passUnretained(context).toOpaque()) == 1 else {
                throw NativeHapticsError.system(L10n.text("Could not start the Bluetooth adapter"), EIO)
            }
            running = true
            status = L10n.text("Searching for controller")
            detail = L10n.text("Hold SYNC on top of the controller until the player LEDs flash.")
            let expiryTimer = Timer(timeInterval: 0.025, repeats: true) { _ in
                MainActor.assumeIsolated { BridgeModel.shared.expireRumble() }
            }
            RunLoop.main.add(expiryTimer, forMode: .common)
            timer = expiryTimer
        } catch {
            native.stop()
            await virtual.stop()
            callbackContext = nil
            status = L10n.text("Connection failed")
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
        let stopped = ns2_shutdown(L10n.text("User disconnect"), 350)
        callbackContext = nil
        await virtual.stop()
        status = L10n.text("Disconnected")
        detail = L10n.text(stopped == 1 ? "Controller released. You can connect it to another app." : "Connection closed, but submission of the rumble stop report was not confirmed.")
        busy = false
    }

    fileprivate func receiveStatus(session: UInt64, value: UInt32, message: String) {
        guard session == self.session, running else { return }
        let wasReady = ready
        update(\.ready, value == NS2_STATUS_READY.rawValue)
        if ready && !wasReady {
            connectedSince = Date()
            refreshDeviceInfo()
            Task {
                guard session == self.session, self.ready else { return }
                await virtual.setRumbleSuppressed(false)
            }
        }
        switch value {
        case NS2_STATUS_READY.rawValue: update(\.status, L10n.text("Controller connected")); update(\.detail, L10n.text("The player LED should stay on. System controller input, standard rumble, and the dual-frequency interface are available."))
        case NS2_STATUS_SCANNING.rawValue: update(\.status, L10n.text("Searching for controller"))
        case NS2_STATUS_CONNECTING.rawValue: update(\.status, L10n.text("Connecting to controller"))
        case NS2_STATUS_INITIALIZING.rawValue: update(\.status, L10n.text("Initializing controller"))
        case NS2_STATUS_DISCONNECTED.rawValue: update(\.status, L10n.text("Connection interrupted")); update(\.detail, L10n.text("Press a controller button to wake it, or hold SYNC to reconnect."))
        case NS2_STATUS_ERROR.rawValue, NS2_STATUS_UNAVAILABLE.rawValue: update(\.status, L10n.text("Controller unavailable")); update(\.detail, message)
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
        input.receive(ControllerInputSnapshot(buttons: buttons, lx: lx, ly: ly, rx: rx, ry: ry))
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
        status = L10n.text("Virtual controller output failed")
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
        if input.isVisible && now - lastInfoDisplay >= 0.25 {
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
        let name = withUnsafeBytes(of: info.name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        update(\.deviceName, name.isEmpty ? L10n.text("Nintendo Switch 2 Pro") : name)
        let identifier = withUnsafeBytes(of: info.identifier) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        update(\.deviceIdentifier, identifier.isEmpty ? L10n.text("Not connected") : identifier)
        update(\.batteryMillivolts, info.battery_known != 0 ? Int(info.battery_millivolts) : nil)
        update(\.batteryLevel, info.battery_level_known != 0 ? Int(info.battery_level) : nil)
        update(\.externalPower, info.external_power_known != 0 ? info.external_power != 0 : nil)
        let error = withUnsafeBytes(of: info.telemetry_error) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        update(\.telemetryError, error)
        update(\.charging, info.charging_known != 0 ? info.charging != 0 : nil)
        update(\.signalStrength, info.rssi_known != 0 ? Int(info.rssi_dbm) : nil)
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<BridgeModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func clearDeviceInfo() {
        update(\.batteryMillivolts, nil)
        update(\.batteryLevel, nil)
        update(\.externalPower, nil)
        update(\.telemetryError, "")
        update(\.charging, nil)
        update(\.signalStrength, nil)
        update(\.connectedSince, nil)
        input.clear()
        update(\.deviceIdentifier, L10n.text("Not connected"))
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
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, isAppWindow(closing), !mayQuit else { return }
        // 菜单栏窗口不参与判断；关闭最后一个普通窗口只隐藏 Dock，不停止手柄服务。
        // Ignore menu-bar panels; closing the last normal window hides the Dock icon without stopping controller services.
        let remaining = NSApp.windows.contains {
            $0 !== closing && isAppWindow($0) && ($0.isVisible || $0.isMiniaturized)
        }
        if !remaining { NSApp.setActivationPolicy(.accessory) }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isAppWindow(window),
              NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
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
    private let model = BridgeModel.shared
    var body: some Scene {
        Window("NS2 Pro Bridge", id: "controller") {
            ControllerDetailView(model: model)
        }
        .defaultSize(width: 560, height: 650)
        .windowResizability(.contentMinSize)
        Settings { BridgeSettingsView(model: model) }
        MenuBarExtra {
            BridgeMenuView(model: model)
        } label: {
            BridgeMenuLabel(model: model)
        }
    }
}

private struct BridgeMenuLabel: View {
    @ObservedObject var model: BridgeModel
    var body: some View {
        Label("NS2 Pro Bridge", systemImage: model.running ? "gamecontroller.fill" : "gamecontroller")
    }
}

private struct BridgeMenuView: View {
    @ObservedObject var model: BridgeModel
    var body: some View {
        ControllerWindowButton()
        Divider()
        Text(model.status).font(.headline)
        Text(model.detail).font(.caption)
        Divider()
        if model.running {
            Button("Disconnect Controller") { Task { await model.disconnect() } }.disabled(model.busy)
        } else {
            Button("Connect Controller") { Task { await model.connect() } }.disabled(model.busy || !model.provisioned)
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit NS2 Pro Bridge") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
