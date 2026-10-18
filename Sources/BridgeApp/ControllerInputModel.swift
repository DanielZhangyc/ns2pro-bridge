import AppKit
import SwiftUI

struct ControllerInputSnapshot: Equatable {
    var buttons: UInt64 = 0
    var lx: Int32 = 0
    var ly: Int32 = 0
    var rx: Int32 = 0
    var ry: Int32 = 0

    var axes: [Double] { [lx, ly, rx, ry].map { Double($0) / 32767 } }
}

@MainActor final class ControllerInputModel: ObservableObject {
    @Published private(set) var snapshot = ControllerInputSnapshot()
    private var latest = ControllerInputSnapshot()
    private var visibleObservers = Set<UUID>()
    private var lastDisplay = 0.0
    var isVisible: Bool { !visibleObservers.isEmpty }

    // 仅限可见窗口的展示节流；系统手柄输入始终由 BridgeModel 逐帧提交。
    // Throttle only visible-window presentation; BridgeModel submits every system-controller input frame.
    func receive(_ input: ControllerInputSnapshot) {
        latest = input
        guard isVisible, input != snapshot else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard input.buttons != snapshot.buttons || now - lastDisplay >= 1.0 / 30 else { return }
        snapshot = input
        lastDisplay = now
    }

    func setVisible(_ visible: Bool, observer: UUID) {
        if visible {
            visibleObservers.insert(observer)
            if snapshot != latest {
                snapshot = latest
                lastDisplay = ProcessInfo.processInfo.systemUptime
            }
        } else {
            visibleObservers.remove(observer)
        }
    }

    func clear() {
        latest = ControllerInputSnapshot()
        if isVisible, snapshot != latest { snapshot = latest }
        lastDisplay = 0
    }
}

struct ControllerInputVisibility: NSViewRepresentable {
    let input: ControllerInputModel

    func makeNSView(context: Context) -> VisibilityView { VisibilityView(input: input) }
    func updateNSView(_ nsView: VisibilityView, context: Context) {}
    static func dismantleNSView(_ nsView: VisibilityView, coordinator: ()) { nsView.stopObserving() }

    @MainActor final class VisibilityView: NSView {
        private let input: ControllerInputModel
        private let observer = UUID()

        init(input: ControllerInputModel) {
            self.input = input
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification] {
                center.addObserver(self, selector: #selector(refreshVisibility), name: name, object: window)
            }
            center.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window)
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                center.addObserver(self, selector: #selector(refreshVisibility), name: name, object: NSApp)
            }
            // 等待窗口挂载完成，避免在 SwiftUI 构建视图期间发布状态。
            // Wait for window attachment to finish before publishing state into SwiftUI.
            DispatchQueue.main.async { [weak self] in self?.refreshVisibility() }
        }

        @objc private func refreshVisibility() {
            let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
            input.setVisible(visible && !NSApp.isHidden, observer: observer)
        }

        @objc private func windowWillClose() {
            input.setVisible(false, observer: observer)
        }

        @objc func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            input.setVisible(false, observer: observer)
        }
    }
}
