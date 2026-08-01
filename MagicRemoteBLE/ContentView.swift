import SwiftUI
import AppKit

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case connection, mapping

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: return "Connection"
        case .mapping: return "Key Mapping"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: return "antenna.radiowaves.left.and.right"
        case .mapping: return "keyboard"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var section: AppSection? = .connection
    @State private var selectedCode: UInt16?
    @State private var selectedLabel = ""

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .listStyle(.sidebar)
        } detail: {
            switch section ?? .connection {
            case .connection:
                ConnectionView()
            case .mapping:
                MappingView(selectedCode: $selectedCode, selectedLabel: $selectedLabel)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 860, minHeight: 560)
        .onChange(of: model.lastButtonCode) { code in
            guard code != 0 else { return }
            selectedCode = code
            selectedLabel = model.displayName(for: code)
        }
        .onChange(of: model.pendingLearnAssign) { code in
            if let code {
                selectedCode = code
                selectedLabel = model.displayName(for: code)
            }
        }
    }
}

// MARK: - Connection

struct ConnectionView: View {
    @EnvironmentObject var model: AppModel
    @State private var logFilter: LogFilter = .all

    private enum LogFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case error = "ERROR"
        case rx = "RX"
        case info = "INFO"

        var id: String { rawValue }

        func matches(_ level: LogLevel) -> Bool {
            switch self {
            case .all: return true
            case .error: return level == .error
            case .rx: return level == .rx || level == .ok || level == .matrix
            case .info: return level == .info || level == .ok || level == .matrix
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Bluetooth") {
                        StatusBadge(
                            text: bluetoothStatusText,
                            tone: model.host.bluetoothOK ? .ok : .error
                        )
                    }
                    LabeledContent("BT Permission") {
                        Text(model.host.bluetoothAuthLabel)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    if !model.host.bluetoothOK {
                        bluetoothRecoverySection
                    }
                    LabeledContent("Bridge") {
                        StatusBadge(text: phaseLabel, tone: phaseTone)
                    }
                    LabeledContent("Remote") {
                        Text(model.host.remoteStatus)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Mouse mode") {
                        StatusBadge(
                            text: model.mapper.mouseMode ? "ON" : "OFF",
                            tone: model.mapper.mouseMode ? .ok : .neutral
                        )
                    }
                    LabeledContent("Events") {
                        Text("\(model.host.eventCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Status")
                }

                Section {
                    LabeledContent("Device") {
                        if let id = model.host.selectedID,
                           let d = model.host.devices.first(where: { $0.id == id }) {
                            Text("\(d.name)  (\(d.rssi) dBm)")
                                .foregroundStyle(.secondary)
                        } else if model.host.phase == .scanning {
                            Text("Searching…")
                                .foregroundStyle(.secondary)
                        } else if model.host.phase == .ready {
                            Text(BridgeUUID.advertisedName)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("—")
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Toggle("Auto-connect", isOn: Binding(
                        get: { model.host.autoConnect },
                        set: { model.host.setAutoConnect($0) }
                    ))

                    Toggle(isOn: Binding(
                        get: { model.mapper.wantsEnabled },
                        set: {
                            model.mapper.setEnabled($0)
                            model.syncPointerOverlay()
                        }
                    )) {
                        Text("Map to Mac input")
                        Text(mapperDetail)
                            .font(.caption)
                            .foregroundStyle(mapperDetailColor)
                    }
                } header: {
                    Text("Bridge")
                } footer: {
                    Text("Auto Scan → Connect when Bluetooth is on. Settings are saved automatically.")
                }

                Section {
                    Toggle("Large pointer (remote)", isOn: $model.largePointer)
                    if model.largePointer {
                        Picker("Pointer Size", selection: $model.pointerSizePreset) {
                            Text("Small").tag(0)
                            Text("Medium").tag(1)
                            Text("Large").tag(2)
                        }
                        .pickerStyle(.segmented)
                    }
                    Toggle("Motion smoothing", isOn: $model.motionSmoothing)
                    Toggle("Native scroll (macOS)", isOn: $model.nativeScroll)
                } header: {
                    Text("Pointer Options")
                } footer: {
                    Text("Large pointer scales the real system cursor while the remote drives, so it stays correct over the Dock and fullscreen video. Native scroll: macOS Natural; off = Windows direction.")
                }

                Section {
                    airmouseSlider(
                        label: "Sensitivity",
                        value: $model.sensitivity,
                        range: AppModel.Airmouse.sensRange,
                        step: 0.001,
                        format: { String(format: "%.3f", $0) }
                    )
                    airmouseSlider(
                        label: "Pointer threshold",
                        value: $model.threshold,
                        range: AppModel.Airmouse.threshRange,
                        step: 10,
                        format: { "\(Int($0))" }
                    )
                    airmouseSlider(
                        label: "Deadzone",
                        value: $model.softDead,
                        range: AppModel.Airmouse.deadRange,
                        step: 1,
                        format: { "\(Int($0))" }
                    )
                    airmouseSlider(
                        label: "Tremor reduction",
                        value: $model.tremorReduction,
                        range: AppModel.Airmouse.tremorRange,
                        step: 0.05,
                        format: { "\(Int(($0 * 100).rounded()))%" }
                    )

                    Button {
                        model.resetAirmouse()
                    } label: {
                        Label("Reset defaults", systemImage: "arrow.counterclockwise")
                    }
                    .help("Sensitivity \(String(format: "%.3f", AppModel.Airmouse.sensDefault)), threshold \(Int(AppModel.Airmouse.threshDefault)), deadzone \(Int(AppModel.Airmouse.deadDefault)), tremor \(Int(AppModel.Airmouse.tremorDefault * 100))%")
                } header: {
                    Text("Airmouse")
                } footer: {
                    Text("Sent to ESP when Ready. Tremor reduction smooths light hand shake; larger deadzone ignores tiny motions at rest.")
                }
            }
            .formStyle(.grouped)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Activity")
                        .font(.headline)
                    Picker("Filter", selection: $logFilter) {
                        ForEach(LogFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    Spacer()
                    Button("Clear") { model.host.clearLogs() }
                        .disabled(model.host.logs.isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)

                Divider()

                List(filteredLogs) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Self.timeFormatter.string(from: entry.time))
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .frame(width: 88, alignment: .leading)
                        Text(entry.level.rawValue)
                            .font(.caption.weight(.semibold).monospaced())
                            .foregroundStyle(color(for: entry.level))
                            .frame(width: 56, alignment: .leading)
                        Text(entry.message)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                }
                .listStyle(.plain)
            }
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .navigationTitle("Connection")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isConnected {
                    Button {
                        model.host.disconnect(userInitiated: true)
                    } label: {
                        Label("Disconnect", systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        model.host.reconnect()
                    } label: {
                        Label(
                            model.host.phase == .scanning || model.host.phase == .connecting
                                ? "Connecting…"
                                : (model.host.phase == .failed ? "Retry" : "Connect"),
                            systemImage: model.host.phase == .failed ? "arrow.clockwise" : "link"
                        )
                    }
                    .disabled(!model.host.bluetoothOK || model.host.phase == .scanning || model.host.phase == .connecting || model.host.phase == .discovering)
                    .keyboardShortcut(.defaultAction)
                }

                Button {
                    model.host.sendCommand([0x01])
                    model.host.log(.ok, "Calibrate command sent")
                } label: {
                    Label("Calibrate", systemImage: "scope")
                }
                .disabled(model.host.phase != .ready)
                .help("Send calib command to ESP32")

                Button {
                    model.pushAirmouseNow()
                } label: {
                    Label("Apply Sens", systemImage: "slider.horizontal.3")
                }
                .disabled(model.host.phase != .ready)
                .help("Push airmouse settings to ESP")

                Button {
                    model.logPerformanceMetrics()
                } label: {
                    Label("Metrics", systemImage: "gauge.with.dots.needle.33percent")
                }
                .help("Write BLE-to-CGEvent latency metrics to Activity")
            }
        }
    }

    private func airmouseSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        format: @escaping (Double) -> String
    ) -> some View {
        /* Avoid Slider minimumValueLabel/maximumValueLabel — on macOS Form they
         * sit beside the track and push the fill/thumb out of alignment. */
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer(minLength: 8)
                Text(format(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
            HStack {
                Text(format(range.lowerBound))
                Spacer()
                Text(format(range.upperBound))
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var bluetoothRecoverySection: some View {
        let auth = model.host.bluetoothAuthLabel
        if auth.contains("Denied") || auth.contains("Restricted") {
            Text("Bluetooth permission blocked — open System Settings and allow MagicRemoteBLE.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Privacy → Bluetooth…") {
                model.host.openBluetoothPrivacySettings()
            }
        } else if auth.contains("NotDetermined") {
            Text("Permission not requested yet — tap below to trigger the system prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Request Bluetooth Permission") {
                model.host.requestBluetoothPermission()
            }
        } else {
            Text("Turn on Bluetooth — the app will auto-connect to MR-Proxy.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Request Bluetooth Permission") {
                model.host.requestBluetoothPermission()
            }
            Button("Open Privacy → Bluetooth…") {
                model.host.openBluetoothPrivacySettings()
            }
        }
    }

    private var bluetoothStatusText: String {
        if model.host.bluetoothOK { return "On" }
        switch model.host.phase {
        case .poweredOff: return "Off"
        default:
            if model.host.bluetoothAuthLabel.contains("Denied") { return "Denied" }
            if model.host.bluetoothAuthLabel.contains("Restricted") { return "Restricted" }
            if model.host.bluetoothAuthLabel.contains("NotDetermined") { return "Not Determined" }
            return "Unavailable"
        }
    }

    private var filteredLogs: [LogEntry] {
        model.host.logs.reversed().filter { logFilter.matches($0.level) }
    }

    private var isConnected: Bool {
        switch model.host.phase {
        case .ready, .connecting, .discovering: return true
        default: return false
        }
    }

    private var phaseLabel: String {
        switch model.host.phase {
        case .idle: return "Idle"
        case .poweredOff: return "Bluetooth Off"
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .discovering: return "Subscribing…"
        case .ready: return "Ready"
        case .failed: return "Failed"
        }
    }

    private var phaseTone: StatusBadge.Tone {
        switch model.host.phase {
        case .ready: return .ok
        case .scanning, .connecting, .discovering: return .busy
        case .failed, .poweredOff: return .error
        case .idle: return .neutral
        }
    }

    private var mapperDetail: String {
        if model.mapper.wantsEnabled && !model.mapper.trusted {
            return "Needs Accessibility permission"
        }
        if !model.mapper.wantsEnabled { return "Off" }
        if !model.mapper.enabled { return "Waiting for Accessibility…" }
        return "Active"
    }

    private var mapperDetailColor: Color {
        if model.mapper.wantsEnabled && !model.mapper.trusted { return .red }
        return .secondary
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .rx: return .green
        case .matrix: return .orange
        case .ok: return .green
        case .info: return .secondary
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// MARK: - Mapping

struct MappingView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selectedCode: UInt16?
    @Binding var selectedLabel: String
    @State private var confirmReset = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Remote")
                    .font(.headline)

                Picker("Input device", selection: Binding(
                    get: { model.activeProfileId },
                    set: { model.selectProfile(id: $0) }
                )) {
                    ForEach(model.availableProfiles) { p in
                        Text(p.displayName).tag(p.id)
                    }
                }

                Text("Click a button or press the remote to select it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                RemotePadView(selectedCode: $selectedCode, selectedLabel: $selectedLabel)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)

                if model.learnMode {
                    Text(learnBanner)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(selectedHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            .background(Color(nsColor: .windowBackgroundColor))

            VStack(spacing: 0) {
                Form {
                    Section {
                        if let code = selectedCode ?? model.pendingLearnAssign {
                            Picker("Assign to", selection: Binding(
                                get: {
                                    let row = model.keyMaps.first { $0.buttonCode == code }
                                    return HIDKeyPresets.matching(mod: row?.mod ?? 0, key: row?.key ?? 0)
                                },
                                set: { model.setPreset(for: code, preset: $0) }
                            )) {
                                ForEach(HIDKeyPresets.allCases) { Text($0.label).tag($0) }
                            }
                        } else {
                            LabeledContent("Assignment") {
                                Text("Select a button")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } header: {
                        Text("Selection")
                    } footer: {
                        Text(mouseModeFooter)
                    }
                }
                .formStyle(.grouped)
                .frame(height: 140)

                if model.keyMaps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "keyboard")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No mappings")
                            .font(.headline)
                        Text("Press Learn or select a pad button to add a mapping.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    Table(model.keyMaps, selection: tableSelection) {
                        TableColumn("Button") { row in
                            Text(row.buttonName)
                        }
                        .width(min: 80, ideal: 100)

                        TableColumn("Code") { row in
                            Text(String(format: "0x%04X", row.buttonCode))
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .width(70)

                        TableColumn("Maps to") { row in
                            let code = row.buttonCode
                            Picker("", selection: Binding(
                                get: {
                                    let r = model.keyMaps.first { $0.buttonCode == code }
                                    return HIDKeyPresets.matching(mod: r?.mod ?? 0, key: r?.key ?? 0)
                                },
                                set: { model.setPreset(for: code, preset: $0) }
                            )) {
                                ForEach(HIDKeyPresets.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                        }
                        .width(min: 120, ideal: 150)

                        TableColumn("On") { row in
                            let code = row.buttonCode
                            /* Only flips `enabled` — clearing the assignment is what the
                               "Off" preset is for, and wiping it here made the checkbox
                               and the "Maps to" column disagree. */
                            Toggle("On", isOn: Binding(
                                get: {
                                    model.keyMaps.first { $0.buttonCode == code }?.enabled ?? false
                                },
                                set: { on in
                                    guard var r = model.keyMaps.first(where: { $0.buttonCode == code }) else { return }
                                    r.enabled = on
                                    model.applyMap(r)
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .disabled((model.keyMaps.first { $0.buttonCode == code }?.key ?? 0) == 0)
                            .help((model.keyMaps.first { $0.buttonCode == code }?.key ?? 0) == 0
                                  ? "Pick a key in “Maps to” first"
                                  : "Enable or disable this mapping")
                        }
                        .width(40)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
            .frame(minWidth: 420)
        }
        .navigationTitle("Key Mapping")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.learnMode {
                    Button {
                        model.cancelLearn()
                    } label: {
                        Label("Cancel Learn", systemImage: "xmark.circle")
                    }
                    .help("Cancel learn mode (also auto-cancels after 20s)")
                } else {
                    Button {
                        model.startLearn()
                    } label: {
                        Label("Learn", systemImage: "plus.viewfinder")
                    }
                    .disabled(model.host.phase != .ready)
                    .help("Press a remote button to add or rename a mapping")
                }

                Button {
                    confirmReset = true
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .help("Restore default key map")
            }
        }
        .confirmationDialog(
            "Reset key mapping?",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("Restore Defaults", role: .destructive) {
                model.resetMaps()
                selectedCode = nil
                selectedLabel = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces all custom mappings with the \(model.activeProfile.displayName) defaults.")
        }
    }

    private var mouseModeFooter: String {
        let b = model.activeProfile.resolvedMouseCodes
        let left = b.left.map { model.activeProfile.name(for: $0) } ?? "—"
        let right = b.right.map { model.activeProfile.name(for: $0) } ?? "—"
        let back = b.back.map { model.activeProfile.name(for: $0) } ?? "—"
        return "Assign Siri / Mouse toggle to any key. Mouse ON: \(left)=left click, \(right)=right, \(back)=mouse Back; tilt moves the pointer."
    }

    private var learnBanner: String {
        let name = model.learnPromptLabel
        if name.isEmpty {
            return "Learning… press any remote button · Cancel or auto-timeout 20s"
        }
        return "Learning “\(name)” — press that remote button · Cancel or auto-timeout 20s"
    }

    private var tableSelection: Binding<Set<String>> {
        Binding(
            get: {
                if let code = selectedCode { return [String(format: "%04X", code)] }
                return []
            },
            set: { ids in
                guard let id = ids.first,
                      let code = UInt16(id, radix: 16) else { return }
                selectedCode = code
                selectedLabel = model.displayName(for: code)
            }
        )
    }

    private var selectedHint: String {
        if let code = selectedCode {
            let name = selectedLabel.isEmpty ? model.displayName(for: code) : selectedLabel
            let preset = model.keyMaps.first { $0.buttonCode == code }
                .map { HIDKeyPresets.matching(mod: $0.mod, key: $0.key).label } ?? "—"
            let mouseCodes = model.activeProfile.resolvedMouseCodes
            let isMouseBound = model.mapper.mouseMode && (
                code == mouseCodes.left || code == mouseCodes.right || code == mouseCodes.back
            )
            let mouseNote = isMouseBound ? " (mouse mode override)" : ""
            return "\(name)  ·  0x\(String(format: "%04X", code))  →  \(preset)\(mouseNote)"
        }
        if model.learnMode {
            let name = model.learnPromptLabel
            return name.isEmpty
                ? "Waiting for a remote button…"
                : "Learning “\(name)” — press the button on the remote"
        }
        return "Select a button on the pad or press the remote"
    }
}

// MARK: - Status badge

private struct StatusBadge: View {
    enum Tone { case ok, busy, error, neutral }

    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch tone {
        case .ok: return .green
        case .busy: return .orange
        case .error: return .red
        case .neutral: return .secondary
        }
    }
}
