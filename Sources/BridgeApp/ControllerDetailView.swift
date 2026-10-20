import SwiftUI
import AppKit

struct ControllerWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show Controller") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "controller")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct ControllerDetailView: View {
    @ObservedObject var model: BridgeModel
    @State private var detailsExpanded = false

    var body: some View {
        Form {
            Section {
                ControllerLiveDiagram(input: model.input)
                LabeledContent("Nintendo Switch 2 Pro", value: model.status)
                if model.ready {
                    ControllerPressedButtons(input: model.input)
                }
            } footer: {
                if !model.ready { Text(model.detail) }
            }
            if model.batteryLevel != nil || model.charging != nil {
                Section("Battery") {
                    if let level = model.batteryLevel {
                        LabeledContent("Battery Level") {
                            HStack(spacing: 8) {
                                ProgressView(value: Double(level), total: 9).frame(width: 90)
                                    .accessibilityLabel("Battery Level").accessibilityValue(L10n.format("%lld / 9", level))
                                Text(L10n.format("%lld / 9", level)).monospacedDigit()
                            }
                        }
                    }
                    if let charging = model.charging {
                        LabeledContent("Charging Status", value: L10n.text(charging ? "Charging" : "Not charging"))
                    }
                    if let externalPower = model.externalPower {
                        LabeledContent("Power Source", value: L10n.text(externalPower ? "External power" : "Battery"))
                    }
                }
            }
            if model.ready {
                Section {
                    if model.motionEnabled {
                        LabeledContent("Gyroscope", value: model.motionSummary.isEmpty
                                       ? L10n.text("Waiting for motion data") : model.motionSummary).monospacedDigit()
                        LabeledContent("Motion Interface", value: "127.0.0.1:26760 (DSU)")
                    }
                    if let connected = model.headsetConnected {
                        LabeledContent("Headphone Jack", value: L10n.text(!connected ? "Not connected"
                            : model.headsetMicrophone == nil ? "Audio accessory connected"
                            : model.headsetMicrophone == true ? "Headset connected" : "Headphones connected"))
                    } else if let raw = model.headsetRawState {
                        LabeledContent("Headphone Jack", value: L10n.format("Unknown state (0x%02X)", raw))
                    }
                    if let state = model.nfcState {
                        LabeledContent("NFC Processor", value: state == 0 ? L10n.text("Idle") : L10n.format("State %lld", state))
                    } else {
                        LabeledContent("NFC Processor", value: L10n.text("Status unavailable"))
                    }
                } header: { Text("Motion and Accessories") }
                footer: { Text("Accessory detection only. NFC tag reading and Bluetooth headphone audio are not available.") }
            }
            Section {
                Button {
                    detailsExpanded.toggle()
                } label: {
                    HStack {
                        Image(systemName: detailsExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("Device and Input Details")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(L10n.text(detailsExpanded ? "Expanded" : "Collapsed"))
                if detailsExpanded {
                    if let millivolts = model.batteryMillivolts {
                        LabeledContent("Battery Voltage", value: L10n.format("%.3f V", Double(millivolts) / 1000)).monospacedDigit()
                    }
                    if let signal = model.signalStrength {
                        LabeledContent("Signal at Discovery", value: L10n.format("%lld dBm", signal))
                    }
                    if model.ready {
                        LabeledContent("Name", value: model.deviceName)
                        LabeledContent("Connection", value: L10n.text("Bluetooth LE"))
                        ControllerStickValues(input: model.input)
                        LabeledContent("Identifier") {
                            Text(model.deviceIdentifier).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if model.running { LabeledContent("System Controller", value: L10n.text("Xbox Wireless Controller")) }
                }
            } footer: {
                if !model.telemetryError.isEmpty { Text(model.telemetryError) }
            }
        }
        .formStyle(.grouped)
        .background(ControllerInputVisibility(input: model.input).frame(width: 0, height: 0))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        if model.running { await model.disconnect() }
                        else { await model.connect() }
                    }
                } label: {
                    ZStack {
                        Image(systemName: model.running ? "xmark" : "link")
                            .opacity(model.busy || (model.running && !model.ready) ? 0 : 1)
                        if model.busy || (model.running && !model.ready) {
                            ProgressView().controlSize(.small)
                        }
                    }.frame(width: 20, height: 20)
                }
                .accessibilityLabel(L10n.text(model.running ? (model.ready ? "Disconnect Controller" : "Cancel Connection") : "Connect Controller"))
                .help(L10n.text(model.running ? (model.ready ? "Disconnect Controller" : "Cancel Connection") : "Connect Controller"))
                .disabled(model.busy || (!model.running && !model.provisioned))
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Image(systemName: "gearshape").frame(width: 20, height: 20) }
                    .accessibilityLabel("Settings").help("Settings")
            }
        }
        .frame(minWidth: 480, minHeight: 570)
    }
}

private struct ControllerLiveDiagram: View {
    @ObservedObject var input: ControllerInputModel
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            ControllerInputDiagram(buttons: input.snapshot.buttons, axes: input.snapshot.axes)
            Spacer(minLength: 0)
        }
    }
}

private struct ControllerPressedButtons: View {
    @ObservedObject var input: ControllerInputModel
    private static let buttonNames = ["A", "B", "X", "Y", "Left stick", "Right stick", "L", "R", "ZL", "ZR", "+", "−", "←", "↑", "→", "↓", "Home", "Capture", "C", "GL", "GR"].map { L10n.text($0) }
    var body: some View {
        LabeledContent("Pressed Buttons") {
            let names = Self.buttonNames.enumerated().compactMap { index, name in
                input.snapshot.buttons & (UInt64(1) << index) != 0 ? name : nil
            }
            Text(names.isEmpty ? L10n.text("None") : names.joined(separator: L10n.text(", ")))
                .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

private struct ControllerStickValues: View {
    @ObservedObject var input: ControllerInputModel
    var body: some View {
        let axes = input.snapshot.axes
        LabeledContent("Left Stick", value: L10n.format("%+.2f, %+.2f", axes[0], axes[1])).monospacedDigit()
        LabeledContent("Right Stick", value: L10n.format("%+.2f, %+.2f", axes[2], axes[3])).monospacedDigit()
    }
}

struct BridgeSettingsView: View {
    @ObservedObject var model: BridgeModel
    var body: some View {
        Form {
            Section {
                Picker("Rumble Strength", selection: $model.gain) {
                    Text("1×").tag(1.0)
                    Text("2× (Default)").tag(2.0)
                    Text("3×").tag(3.0)
                }.disabled(model.running || model.busy)
                LabeledContent("Both Motors") { Button("Test") { model.testRumble() }.disabled(!model.ready) }
            } footer: { Text("The test lasts 0.3 seconds. Disconnect the controller before changing the strength.") }
            Section {
                Toggle("Allow local apps to send dual-frequency rumble", isOn: $model.nativeEnabled).disabled(model.running || model.busy)
            } header: { Text("Dual-Frequency Interface") }
            footer: { Text("Standard games provide left and right intensity. Dual-frequency effects require app integration. Disconnect the controller before changing this setting.") }
            Section {
                Toggle("Share motion with local apps (DSU)", isOn: $model.motionEnabled).disabled(model.running || model.busy)
                if model.motionEnabled {
                    LabeledContent("Server", value: "127.0.0.1:26760")
                }
            } header: { Text("Experimental Motion Interface") }
            footer: { Text("Select DSU slot 0 in a compatible app. Disconnect before changing this setting. Motion mode uses a separate report; firmware battery level, charging, and NFC status are unavailable. Device axes and emulator behavior still need hardware validation.") }
            Section {
                LabeledContent("A / B / X / Y", value: L10n.text("Xbox B / A / Y / X"))
                LabeledContent("Home / Capture", value: L10n.text("Guide / Share"))
            } header: { Text("System Mapping") }
            footer: { Text("Buttons map by physical position. C, GL, and GR are visible in the main window but are not mapped to the system controller.") }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 600)
    }
}
