import Foundation
import Combine

@MainActor
final class DongleModel: ObservableObject {
    let serial = SerialPort()

    @Published var sensitivity: Double = 0.045
    @Published var threshold: Double = 280
    @Published var deadzone: Double = 28
    @Published var invertY = false
    @Published var invertX = false
    @Published var learnMode = false
    @Published var keyMaps: [KeyMapRow] = KeyMapRow.defaults
    @Published var lastButtonCode: UInt16 = 0
    @Published var lastButtonName = "—"
    @Published var statusLine = "Chưa kết nối Serial"
    @Published var pointerMode = false
    @Published var logs: [LogEntry] = []
    @Published var pendingLearnAssign: UInt16?
    @Published var pendingLearnLabel: String = ""

    private var pushTask: Task<Void, Never>?
    private var suppressPush = false

    init() {
        loadPrefs()
        serial.onLog = { [weak self] level, msg in self?.append(level, msg) }
        serial.onLine = { [weak self] line in self?.handleLine(line) }
        serial.refreshPorts()

        // Debounce slider → ESP32
        pushTask = Task { [weak self] in
            var lastSens = -1.0, lastTh = -1.0, lastDead = -1.0
            var lastInvY: Bool?
            var lastInvX: Bool?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, self.serial.state == .open, !self.suppressPush else { continue }
                if abs(self.sensitivity - lastSens) > 0.0001 {
                    lastSens = self.sensitivity
                    self.serial.send(String(format: "CFG SENS %.4f", self.sensitivity))
                }
                if abs(self.threshold - lastTh) > 0.5 {
                    lastTh = self.threshold
                    self.serial.send(String(format: "CFG THRESH %.0f", self.threshold))
                }
                if abs(self.deadzone - lastDead) > 0.5 {
                    lastDead = self.deadzone
                    self.serial.send(String(format: "CFG DEAD %.0f", self.deadzone))
                }
                if lastInvY != self.invertY {
                    lastInvY = self.invertY
                    self.serial.send("CFG INVERTY \(self.invertY ? 1 : 0)")
                }
                if lastInvX != self.invertX {
                    lastInvX = self.invertX
                    self.serial.send("CFG INVERTX \(self.invertX ? 1 : 0)")
                }
                self.savePrefs()
            }
        }
    }

    func connect() {
        serial.connect()
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            pushAll()
        }
    }

    func disconnect() {
        serial.disconnect()
        statusLine = "Ngắt Serial"
    }

    func recalibrate() {
        serial.send("CFG CALIB")
    }

    /// SCAN lại remote đã nhớ (giữ bond/NVS). Bấm nút remote để đánh thức.
    func connectRemote() {
        guard serial.state == .open else {
            append(.error, "Mở Serial trước")
            return
        }
        serial.send("CFG SCANREMOTE")
        append(.info, "Scan remote (giữ nhớ) — bấm nút trên remote")
        statusLine = "Đang SCAN remote…"
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            serial.send("CFG GET")
        }
    }

    /// Quên remote + pair lại từ đầu.
    func pairRemoteAgain() {
        guard serial.state == .open else { return }
        serial.send("CFG PAIRREMOTE")
        append(.info, "Pair lại — remote cần pair mode / gần ESP32")
        statusLine = "Đang pair remote…"
    }

    /// Chỉ quên remote đã lưu (không tự scan).
    func forgetRemote() {
        guard serial.state == .open else { return }
        serial.send("CFG FORGETREMOTE")
        append(.info, "Đã gửi FORGETREMOTE")
    }

    /// Đưa độ nhạy / ngưỡng / deadzone / đảo trục về mặc định firmware.
    func resetAirmouseDefaults() {
        suppressPush = true
        sensitivity = 0.045
        threshold = 280
        deadzone = 28
        invertX = false
        invertY = false
        suppressPush = false
        savePrefs()
        if serial.state == .open {
            serial.send(String(format: "CFG SENS %.4f", sensitivity))
            serial.send(String(format: "CFG THRESH %.0f", threshold))
            serial.send(String(format: "CFG DEAD %.0f", deadzone))
            serial.send("CFG INVERTX 0")
            serial.send("CFG INVERTY 0")
            serial.send("CFG CALIB")
        }
        append(.ok, "Airmouse reset mặc định (sens=0.045 thresh=280 dead=28)")
    }

    func refreshStatus() {
        serial.send("CFG GET")
    }

    func startLearn(label: String = "") {
        learnMode = true
        pendingLearnAssign = nil
        pendingLearnLabel = label
        serial.send("CFG LEARN 1")
        append(.info, label.isEmpty ? "Learn: bấm 1 nút trên remote…" : "Learn «\(label)»: bấm đúng nút trên remote")
    }

    func applyMap(_ row: KeyMapRow) {
        guard !row.isFixedMouse else {
            append(.info, "\(row.buttonName) cố định \(row.fixedMouseLabel ?? "chuột") — không remap")
            return
        }
        if let idx = keyMaps.firstIndex(where: { $0.buttonCode == row.buttonCode }) {
            keyMaps[idx] = row
        } else {
            keyMaps.append(row)
            keyMaps.sort { $0.buttonCode < $1.buttonCode }
        }
        if row.enabled && row.key != 0 {
            serial.send(String(format: "CFG MAP %04X %02X %02X", row.buttonCode, row.mod, row.key))
        } else {
            serial.send(String(format: "CFG UNMAP %04X", row.buttonCode))
        }
        savePrefs()
    }

    func setPreset(for code: UInt16, preset: HIDKeyPresets) {
        guard !KeyMapRow.fixedMouseCodes.contains(code) else {
            append(.info, "\(KeyMapRow.name(for: code)) cố định chuột — không remap")
            return
        }
        let (mod, key) = preset.modKey
        let row = KeyMapRow(
            buttonCode: code,
            buttonName: KeyMapRow.name(for: code),
            mod: mod,
            key: key,
            enabled: preset != .none
        )
        applyMap(row)
    }

    func resetMaps() {
        serial.send("CFG MAPCLR")
        keyMaps = KeyMapRow.defaults
        for row in keyMaps where !row.isFixedMouse && row.enabled && row.key != 0 {
            serial.send(String(format: "CFG MAP %04X %02X %02X", row.buttonCode, row.mod, row.key))
        }
        savePrefs()
    }

    func pushAll() {
        suppressPush = true
        serial.send(String(format: "CFG SENS %.4f", sensitivity))
        serial.send(String(format: "CFG THRESH %.0f", threshold))
        serial.send(String(format: "CFG DEAD %.0f", deadzone))
        serial.send("CFG INVERTY \(invertY ? 1 : 0)")
        serial.send("CFG INVERTX \(invertX ? 1 : 0)")
        serial.send("CFG MAPCLR")
        for row in keyMaps where !row.isFixedMouse && row.enabled && row.key != 0 {
            serial.send(String(format: "CFG MAP %04X %02X %02X", row.buttonCode, row.mod, row.key))
        }
        serial.send("CFG GET")
        suppressPush = false
    }

    private func handleLine(_ line: String) {
        if line.hasPrefix("CFG VOICE ") {
            let rest = String(line.dropFirst(10))
            if rest.hasPrefix("1") {
                let msg = SiriController.activate()
                append(.ok, "VOICE DOWN → \(msg)")
                statusLine = "Siri / Voice…"
            } else {
                append(.info, "VOICE UP \(rest)")
                statusLine = "Voice ended"
            }
            return
        }
        if line.hasPrefix("CFG AUD ") {
            append(.rx, line)
            return
        }
        if line.hasPrefix("CFG OK CONNECTREMOTE") || line.hasPrefix("CFG OK SCANREMOTE") || line.hasPrefix("CFG OK PAIRREMOTE") {
            statusLine = line
            append(.ok, "\(line) — bấm nút remote")
            return
        }
        if line.contains("CONNECTREMOTE scanning") {
            statusLine = "SCAN remote…"
            append(.ok, "Đang SCAN LGE MR25GA — bấm nút trên remote")
            return
        }
        if line.hasPrefix("CFG ERR CONNECTREMOTE") {
            statusLine = line
            append(.error, line)
            return
        }
        if line.hasPrefix("CFG ERR unknown") {
            append(.error, "Firmware chưa hỗ trợ lệnh — nạp lại esp32-hid-dongle.ino")
            return
        }
        if line.hasPrefix("CFG STATUS") && line.contains("paired=") {
            if line.contains("paired=1") {
                append(.info, "Remote đã được nhớ (paired=1)")
            }
        }
        if line.hasPrefix("CFG OK") || line.hasPrefix("CFG STATUS") {
            parseCfgOK(line)
            statusLine = line
            append(.ok, line)
            return
        }
        if line.hasPrefix("CFG BTN ") {
            let hex = String(line.dropFirst(8))
            if let code = UInt16(hex, radix: 16) {
                lastButtonCode = code
                lastButtonName = code == 0 ? "Released" : KeyMapRow.name(for: code)
            }
            return
        }
        if line.hasPrefix("CFG LEARNED ") {
            let hex = String(line.dropFirst(12))
            if let code = UInt16(hex, radix: 16), code != 0 {
                pendingLearnAssign = code
                learnMode = false
                lastButtonCode = code
                let name = pendingLearnLabel.isEmpty ? KeyMapRow.name(for: code) : pendingLearnLabel
                lastButtonName = name
                append(.rx, "Learn được \(name) (0x\(hex)) — chọn phím bên dưới")
                if let idx = keyMaps.firstIndex(where: { $0.buttonCode == code }) {
                    keyMaps[idx].buttonName = name
                } else {
                    keyMaps.append(KeyMapRow(
                        buttonCode: code,
                        buttonName: name,
                        mod: 0,
                        key: 0x28,
                        enabled: true
                    ))
                }
                pendingLearnLabel = ""
            }
            return
        }
        if line.hasPrefix("CFG MAP ") {
            // CFG MAP bbbb mm kk active
            let parts = line.split(separator: " ")
            if parts.count >= 5,
               let btn = UInt16(parts[2], radix: 16),
               let mod = UInt8(parts[3], radix: 16),
               let key = UInt8(parts[4], radix: 16) {
                guard !KeyMapRow.fixedMouseCodes.contains(btn) else { return }
                let active = parts.count > 5 ? (Int(parts[5]) ?? 1) != 0 : true
                let row = KeyMapRow(
                    buttonCode: btn,
                    buttonName: KeyMapRow.name(for: btn),
                    mod: mod,
                    key: key,
                    enabled: active && key != 0
                )
                if let idx = keyMaps.firstIndex(where: { $0.buttonCode == btn }) {
                    keyMaps[idx] = row
                } else {
                    keyMaps.append(row)
                }
            }
            return
        }
        if line.hasPrefix("CFG ERR") {
            append(.error, line)
            return
        }
        // HB / interesting debug
        if line.contains("HB ph=") || line.contains("MAC BONDED") || line.contains("REMOTE")
            || line.contains("gyro bias") || line.contains("BOOT") {
            append(.info, line)
            if line.contains("PTR=") || line.contains("airmouse") || line.contains("pointer") {
                pointerMode = line.contains("PTR=1")
            }
        }
    }

    private func parseCfgOK(_ line: String) {
        // CFG OK SENS=0.0450 THRESH=280 DEAD=28 INVERTY=0 LEARN=0 OVR=0 PTR=1
        func val(_ key: String) -> String? {
            guard let r = line.range(of: "\(key)=") else { return nil }
            let rest = line[r.upperBound...]
            let end = rest.firstIndex(where: { $0 == " " }) ?? rest.endIndex
            return String(rest[..<end])
        }
        suppressPush = true
        if let s = val("SENS"), let v = Double(s) { sensitivity = v }
        if let s = val("THRESH"), let v = Double(s) { threshold = v }
        if let s = val("DEAD"), let v = Double(s) { deadzone = v }
        if let s = val("INVERTY") { invertY = (Int(s) ?? 0) != 0 }
        if let s = val("INVERTX") { invertX = (Int(s) ?? 0) != 0 }
        if let s = val("LEARN") { learnMode = (Int(s) ?? 0) != 0 }
        if let s = val("PTR") { pointerMode = (Int(s) ?? 0) != 0 }
        suppressPush = false
    }

    private func append(_ level: LogLevel, _ message: String) {
        logs.append(LogEntry(level: level, message: message))
        if logs.count > 300 {
            logs.removeFirst(logs.count - 300)
        }
    }

    private func savePrefs() {
        UserDefaults.standard.set(sensitivity, forKey: "sens")
        UserDefaults.standard.set(threshold, forKey: "thresh")
        UserDefaults.standard.set(deadzone, forKey: "dead")
        UserDefaults.standard.set(invertY, forKey: "inverty")
        UserDefaults.standard.set(invertX, forKey: "invertx")
        if let data = try? JSONEncoder().encode(keyMaps) {
            UserDefaults.standard.set(data, forKey: "keymaps")
        }
    }

    private func loadPrefs() {
        let d = UserDefaults.standard
        if d.object(forKey: "sens") != nil { sensitivity = d.double(forKey: "sens") }
        if d.object(forKey: "thresh") != nil { threshold = d.double(forKey: "thresh") }
        if d.object(forKey: "dead") != nil { deadzone = d.double(forKey: "dead") }
        // Deadzone từng bị đẩy lên 65 (cứng) — kéo về khoảng mượt nếu quá cao
        if deadzone > 50 { deadzone = 28 }
        invertY = d.bool(forKey: "inverty")
        invertX = d.bool(forKey: "invertx")
        if let data = d.data(forKey: "keymaps"),
           let rows = try? JSONDecoder().decode([KeyMapRow].self, from: data),
           !rows.isEmpty {
            keyMaps = rows.map { row in
                guard row.isFixedMouse else { return row }
                var fixed = row
                fixed.mod = 0
                fixed.key = 0
                fixed.enabled = true
                return fixed
            }
            // Đảm bảo OK/Settings luôn có trong list
            for def in KeyMapRow.defaults where def.isFixedMouse {
                if !keyMaps.contains(where: { $0.buttonCode == def.buttonCode }) {
                    keyMaps.append(def)
                }
            }
        }
    }
}
