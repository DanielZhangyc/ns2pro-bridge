import SwiftUI
import AppKit

struct ControllerWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("显示手柄") {
            openWindow(id: "controller")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct ControllerDetailView: View {
    @ObservedObject var model: BridgeModel
    @State private var detailsExpanded = false
    private let buttonNames = ["A", "B", "X", "Y", "左摇杆", "右摇杆", "L", "R", "ZL", "ZR", "+", "−", "←", "↑", "→", "↓", "Home", "截图", "C", "GL", "GR"]

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer(minLength: 0)
                    ControllerInputDiagram(buttons: model.buttons, axes: model.axes)
                    Spacer(minLength: 0)
                }
                LabeledContent("Nintendo Switch 2 Pro", value: model.status)
                if model.ready {
                    LabeledContent("按下的按键") {
                        let names = buttonNames.enumerated().compactMap { index, name in
                            model.buttons & (UInt64(1) << index) != 0 ? name : nil
                        }
                        Text(names.isEmpty ? "无" : names.joined(separator: "、"))
                            .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
            } footer: {
                if !model.ready { Text(model.detail) }
            }
            if model.batteryLevel != nil || model.charging != nil {
                Section("电池") {
                    if let level = model.batteryLevel {
                        LabeledContent("电量等级") {
                            HStack(spacing: 8) {
                                ProgressView(value: Double(level), total: 9).frame(width: 90)
                                    .accessibilityLabel("电量等级").accessibilityValue("\(level) / 9")
                                Text("\(level) / 9").monospacedDigit()
                            }
                        }
                    }
                    if let charging = model.charging {
                        LabeledContent("充电状态", value: charging ? "正在充电" : "未在充电")
                    }
                    if let externalPower = model.externalPower {
                        LabeledContent("电源", value: externalPower ? "外部供电" : "电池")
                    }
                }
            }
            Section {
                Button {
                    detailsExpanded.toggle()
                } label: {
                    HStack {
                        Image(systemName: detailsExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text("设备与输入详情")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(detailsExpanded ? "已展开" : "已收起")
                if detailsExpanded {
                    if let millivolts = model.batteryMillivolts {
                        LabeledContent("电池电压", value: String(format: "%.3f V", Double(millivolts) / 1000)).monospacedDigit()
                    }
                    if let signal = model.signalStrength {
                        LabeledContent("发现时信号", value: "\(signal) dBm")
                    }
                    if model.ready {
                        LabeledContent("名称", value: model.deviceName)
                        LabeledContent("连接方式", value: "Bluetooth LE")
                        LabeledContent("左摇杆", value: String(format: "%+.2f, %+.2f", model.axes[0], model.axes[1])).monospacedDigit()
                        LabeledContent("右摇杆", value: String(format: "%+.2f, %+.2f", model.axes[2], model.axes[3])).monospacedDigit()
                        LabeledContent("标识符") {
                            Text(model.deviceIdentifier).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    if model.running { LabeledContent("系统手柄", value: "Xbox Wireless Controller") }
                }
            } footer: {
                if !model.telemetryError.isEmpty { Text(model.telemetryError) }
            }
        }
        .formStyle(.grouped)
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
                .accessibilityLabel(model.running ? (model.ready ? "断开手柄" : "取消连接") : "连接手柄")
                .help(model.running ? (model.ready ? "断开手柄" : "取消连接") : "连接手柄")
                .disabled(model.busy || (!model.running && !model.provisioned))
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Image(systemName: "gearshape").frame(width: 20, height: 20) }
                    .accessibilityLabel("设置").help("设置")
            }
        }
        .frame(minWidth: 480, minHeight: 570)
    }
}

struct BridgeSettingsView: View {
    @ObservedObject var model: BridgeModel
    var body: some View {
        Form {
            Section {
                Picker("震动力度", selection: $model.gain) {
                    Text("1 倍").tag(1.0)
                    Text("2 倍（默认）").tag(2.0)
                    Text("3 倍").tag(3.0)
                }.disabled(model.running || model.busy)
                LabeledContent("双侧震动") { Button("测试") { model.testRumble() }.disabled(!model.ready) }
            } footer: { Text("测试持续 0.3 秒。修改力度前，请先断开手柄。") }
            Section {
                Toggle("允许本机应用发送双频震动", isOn: $model.nativeEnabled).disabled(model.running || model.busy)
            } header: { Text("双频接口") }
            footer: { Text("普通游戏提供左右强度。双频效果需要应用主动接入。修改此设置前，请先断开手柄。") }
            Section {
                LabeledContent("A / B / X / Y", value: "Xbox B / A / Y / X")
                LabeledContent("Home / 截图", value: "Guide / Share")
            } header: { Text("系统映射") }
            footer: { Text("按物理位置映射。C、GL、GR 可在主页查看，但暂不映射到系统手柄。") }
        }
        .formStyle(.grouped)
        .frame(width: 470, height: 420)
    }
}
