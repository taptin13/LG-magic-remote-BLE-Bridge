import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: DongleModel
    @State private var selectedCode: UInt16?
    @State private var selectedLabel = ""

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            serialBar
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Remote MR25GA — chạm nút để map")
                        .font(.caption.weight(.semibold))
                    RemotePadView(selectedCode: $selectedCode, selectedLabel: $selectedLabel)
                    Text(selectedHint)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 300, alignment: .leading)
                }
                .frame(width: 300)

                VStack(alignment: .leading, spacing: 12) {
                    airmouseBox
                    mapBox
                }
                .frame(maxWidth: .infinity)
            }

            Text(model.statusLine)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            logList
        }
        .padding(16)
        .onChange(of: model.lastButtonCode) { code in
            guard code != 0 else { return }
            selectedCode = code
            selectedLabel = model.lastButtonName
        }
        .onChange(of: model.pendingLearnAssign) { code in
            if let code {
                selectedCode = code
                selectedLabel = KeyMapRow.name(for: code)
            }
        }
    }

    private var selectedHint: String {
        if let code = selectedCode {
            if KeyMapRow.fixedMouseCodes.contains(code) {
                let label = code == 0x8044 ? "Chuột trái" : "Chuột phải"
                return "\(selectedLabel.isEmpty ? KeyMapRow.name(for: code) : selectedLabel) → \(label) (cố định, không remap)"
            }
            let preset = model.keyMaps.first { $0.buttonCode == code }
                .map { HIDKeyPresets.matching(mod: $0.mod, key: $0.key).label } ?? "—"
            return "Đang chọn: \(selectedLabel.isEmpty ? KeyMapRow.name(for: code) : selectedLabel)  0x\(String(format: "%04X", code)) → \(preset)"
        }
        if !selectedLabel.isEmpty {
            return "Đang Learn: \(selectedLabel) — bấm nút trên remote"
        }
        return "Chạm nút trên ảnh, hoặc bấm remote (ô xanh = đang nhấn)"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MR-Dongle Config")
                .font(.title2.weight(.semibold))
            Text("USB Serial → độ nhạy / calib / map. HID BLE vẫn tới Mac trực tiếp.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var serialBar: some View {
        HStack(spacing: 10) {
            Button("Refresh") { model.serial.refreshPorts() }
            Picker("Port", selection: model.serial.portBinding) {
                ForEach(model.serial.ports, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 280)

            if model.serial.state == .open {
                Button("Ngắt") { model.disconnect() }
                Button("Đồng bộ") { model.pushAll() }
                Button("Status") { model.refreshStatus() }
                Button("Connect remote") { model.connectRemote() }
                    .help("SCAN lại remote đã nhớ (không xóa bond). Bấm nút remote để đánh thức.")
                Button("Pair lại") { model.pairRemoteAgain() }
                    .help("Quên remote + pair mới (khi Connect remote không đủ).")
                    .disabled(model.serial.state != .open)
            } else {
                Button("Kết nối") { model.connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.serial.selectedPort.isEmpty)
            }

            Spacer()
            Text(model.serial.state.rawValue)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var airmouseBox: some View {
        GroupBox("Airmouse") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Độ nhạy \(String(format: "%.3f", model.sensitivity))")
                        .frame(width: 110, alignment: .leading)
                    Slider(value: $model.sensitivity, in: 0.01...0.20)
                }
                HStack {
                    Text("Ngưỡng \(Int(model.threshold))")
                        .frame(width: 110, alignment: .leading)
                    Slider(value: $model.threshold, in: 50...800)
                }
                HStack {
                    Text("Deadzone \(Int(model.deadzone))")
                        .frame(width: 110, alignment: .leading)
                    Slider(value: $model.deadzone, in: 10...60)
                }
                HStack(spacing: 14) {
                    Toggle("Đảo X", isOn: $model.invertX)
                    Toggle("Đảo Y", isOn: $model.invertY)
                    Button("Calib") { model.recalibrate() }
                        .disabled(model.serial.state != .open)
                    Button("Reset mặc định") { model.resetAirmouseDefaults() }
                    if model.pointerMode {
                        Text("pointer")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer()
                }
            }
            .padding(4)
        }
    }

    private var mapBox: some View {
        GroupBox("Map phím") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(model.learnMode ? "Đang chờ…" : "Learn nút") {
                        model.startLearn()
                    }
                    .disabled(model.serial.state != .open || model.learnMode)

                    if let code = selectedCode ?? model.pendingLearnAssign,
                       !KeyMapRow.fixedMouseCodes.contains(code) {
                        Text("Gán:")
                            .font(.caption)
                        Picker("", selection: Binding(
                            get: {
                                let row = model.keyMaps.first { $0.buttonCode == code }
                                return HIDKeyPresets.matching(mod: row?.mod ?? 0, key: row?.key ?? 0)
                            },
                            set: { model.setPreset(for: code, preset: $0); model.pendingLearnAssign = nil }
                        )) {
                            ForEach(HIDKeyPresets.allCases) { Text($0.label).tag($0) }
                        }
                        .frame(width: 130)
                    }

                    Spacer()
                    Button("Reset mặc định") { model.resetMaps() }
                        .disabled(model.serial.state != .open)
                }

                List {
                    ForEach(model.keyMaps) { row in
                        HStack {
                            Text(row.buttonName)
                                .frame(width: 90, alignment: .leading)
                            Text(String(format: "0x%04X", row.buttonCode))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .leading)
                            if row.isFixedMouse {
                                Text(row.fixedMouseLabel ?? "Chuột")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 130, alignment: .leading)
                                Text("cố định")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            } else {
                                Picker("", selection: Binding(
                                    get: { HIDKeyPresets.matching(mod: row.mod, key: row.key) },
                                    set: { model.setPreset(for: row.buttonCode, preset: $0) }
                                )) {
                                    ForEach(HIDKeyPresets.allCases) { Text($0.label).tag($0) }
                                }
                                .frame(width: 130)
                                Toggle("Bật", isOn: Binding(
                                    get: { row.enabled },
                                    set: { on in
                                        var r = row
                                        r.enabled = on
                                        if !on { r.key = 0; r.mod = 0 }
                                        model.applyMap(r)
                                    }
                                ))
                                .labelsHidden()
                            }
                        }
                        .listRowBackground(
                            selectedCode == row.buttonCode
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                    }
                }
                .frame(minHeight: 180, maxHeight: 260)
            }
            .padding(4)
        }
    }

    private var logList: some View {
        List(model.logs.suffix(60).reversed()) { entry in
            HStack(alignment: .top, spacing: 8) {
                Text(Self.timeFormatter.string(from: entry.time))
                    .frame(width: 90, alignment: .leading)
                    .foregroundStyle(.secondary)
                Text(entry.level.rawValue.uppercased())
                    .frame(width: 36, alignment: .leading)
                    .foregroundStyle(color(for: entry.level))
                Text(entry.message)
                    .textSelection(.enabled)
            }
            .font(.system(.caption2, design: .monospaced))
        }
        .frame(minHeight: 100)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .tx: return .orange
        case .rx: return .blue
        case .ok: return .green
        case .info: return .secondary
        }
    }
}
