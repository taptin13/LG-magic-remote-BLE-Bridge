import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var studio: StudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            bridgeHeader
            Divider()
            header
            Divider()
            logList
            Divider()
            footer
        }
        .padding()
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { studio.bridge.refreshPorts() }
    }

    private var bridgeHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ESP32 bridge (recommended)")
                .font(.headline)

            HStack(spacing: 10) {
                Picker("Port", selection: $studio.bridge.selectedPort) {
                    ForEach(studio.bridge.ports, id: \.self) { port in
                        Text(port.replacingOccurrences(of: "/dev/", with: "")).tag(port)
                    }
                }
                .frame(maxWidth: 280)

                Button("Refresh") { studio.bridge.refreshPorts() }

                if studio.bridge.state == .open {
                    Button("Disconnect") { studio.bridge.disconnect() }
                } else {
                    Button("Connect bridge") { studio.bridge.connect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(studio.bridge.selectedPort.isEmpty)
                }

                Spacer()
                Text("\(studio.bridge.bridgeStatus) · up \(String(format: "%.0f", studio.bridge.linkSeconds))s · \(studio.bridge.hidPacketCount) HID")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let last = studio.bridge.recentReports.last {
                Text("Last: \(last.buttonName)  ctr=\(last.counter)  imu=\(last.imu.map(String.init).joined(separator: ","))  wheel=\(last.wheel)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Text("Nạp firmware bridge lên ESP32, Connect, rồi rê/bấm remote. Mac chỉ decode — BLE chạy trên ESP32.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Toggle("Map → Mac keyboard/mouse", isOn: Binding(
                    get: { studio.mapper.enabled },
                    set: { studio.mapper.setEnabled($0) }
                ))
                Button("Recalib") { studio.mapper.recalibrateBias() }
                    .disabled(!studio.mapper.enabled)
                if studio.mapper.pointerMode {
                    Text("airmouse")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(studio.mapper.status)
                    .font(.caption)
                    .foregroundStyle((studio.mapper.trusted || !studio.mapper.enabled) ? Color.secondary : Color.red)
                Spacer()
                Text("Sens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $studio.mapper.sensitivity, in: 0.01...0.15)
                    .frame(width: 120)
            }
            Text("Bật map → giữ yên ~1s (calib bias). OK=Enter/click · Back=Esc · rê=chuột")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(studio.handshake.running ? "Stop BLE" : "Run BLE (legacy)") {
                    if studio.handshake.running { studio.handshake.stop() } else { studio.handshake.start() }
                }
                .disabled(studio.host.bluetoothState != "Powered on")

                Text(studio.handshake.progress)
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Text(studio.host.sessionState.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("BLE Run trên Mac không bond/HID được (CoreBluetooth). Dùng ESP32 bridge ở trên.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var logList: some View {
        List(studio.host.logs) { entry in
            HStack(alignment: .top, spacing: 8) {
                Text(Self.timeFormatter.string(from: entry.time))
                    .frame(width: 82, alignment: .leading)
                Text(entry.level.rawValue)
                    .frame(width: 56, alignment: .leading)
                    .foregroundStyle(color(for: entry.level))
                Text(entry.message)
                    .textSelection(.enabled)
                    .foregroundStyle(entry.level == .matrix ? .primary : .secondary)
            }
            .font(.system(.caption, design: .monospaced))
        }
    }

    private var footer: some View {
        HStack {
            Button("Export JSONL") { studio.export() }
            Button("Copy log") { copyLog() }
            Button("Clear") {
                studio.recorder.clear()
                studio.host.logs.removeAll()
                studio.bridge.clearReports()
            }
            Spacer()
            Text("\(studio.recorder.events.count) packet(s) · bridge \(studio.bridge.hidPacketCount) HID · BLE resp \(studio.handshake.responseCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .rx: return .green
        case .tx: return .blue
        case .matrix: return .orange
        case .info: return .secondary
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    private func copyLog() {
        let formatter = Self.timeFormatter
        let text = studio.host.logs.map { entry in
            "\(formatter.string(from: entry.time))\t[\(entry.level.rawValue)]\t\(entry.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        studio.host.log(.info, "Copied \(studio.host.logs.count) log line(s) to clipboard")
    }
}
