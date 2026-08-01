import Foundation

enum LogLevel: String {
    case info = "INFO", rx = "RX", matrix = "MATRIX", error = "ERROR", ok = "OK"
}

struct LogEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let level: LogLevel
    let message: String
}

struct HIDFDReport: Identifiable {
    let id = UUID()
    let offset: Int
    let counter: UInt16
    let unknown3: UInt8
    let unknown4: UInt8
    let imu: [Int16]
    let buttonCode: UInt16
    let buttonName: String
    let wheel: Int8
}

struct DiscoveredBridge: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
}

// MARK: - Key mapping

struct KeyMapRow: Identifiable, Codable, Equatable {
    var id: String { String(format: "%04X", buttonCode) }
    var buttonCode: UInt16
    var buttonName: String
    var mod: UInt8
    var key: UInt8
    var enabled: Bool

    /// Fallback display when no active profile catalog entry exists.
    static func name(for code: UInt16, catalog: [UInt16: String] = [:]) -> String {
        catalog[code] ?? String(format: "0x%04X", code)
    }
}

enum HIDKeyPresets: String, CaseIterable, Identifiable {
    case enter, escape, space, up, down, left, right, tab, delete
    case cmdH, cmdComma, cmdQ, cmdW, cmdC, cmdV
    case volUp, volDown, mute
    case siri, mouseToggle
    case a, b, c, none

    /// Pseudo HID — does not conflict with real usage.
    static let siriKey: UInt8 = 0xFE
    static let mouseToggleKey: UInt8 = 0xFD

    var id: String { rawValue }

    var label: String {
        switch self {
        case .enter: return "Enter"
        case .escape: return "Esc"
        case .space: return "Space"
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        case .tab: return "Tab"
        case .delete: return "Delete"
        case .cmdH: return "⌘H"
        case .cmdComma: return "⌘,"
        case .cmdQ: return "⌘Q"
        case .cmdW: return "⌘W"
        case .cmdC: return "⌘C"
        case .cmdV: return "⌘V"
        case .volUp: return "Vol+ (media)"
        case .volDown: return "Vol- (media)"
        case .mute: return "Mute (media)"
        case .siri: return "Siri"
        case .mouseToggle: return "Mouse toggle"
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        case .none: return "Off"
        }
    }

    /// HID keyboard usage. Media: 0xF1/F2/F3. Special: Siri/MouseToggle.
    var modKey: (UInt8, UInt8) {
        switch self {
        case .enter: return (0, 0x28)
        case .escape: return (0, 0x29)
        case .space: return (0, 0x2C)
        case .up: return (0, 0x52)
        case .down: return (0, 0x51)
        case .left: return (0, 0x50)
        case .right: return (0, 0x4F)
        case .tab: return (0, 0x2B)
        case .delete: return (0, 0x2A)
        case .cmdH: return (0x08, 0x0B)
        case .cmdComma: return (0x08, 0x36)
        case .cmdQ: return (0x08, 0x14)
        case .cmdW: return (0x08, 0x1A)
        case .cmdC: return (0x08, 0x06)
        case .cmdV: return (0x08, 0x19)
        case .volUp: return (0, 0xF1)
        case .volDown: return (0, 0xF2)
        case .mute: return (0, 0xF3)
        case .siri: return (0, Self.siriKey)
        case .mouseToggle: return (0, Self.mouseToggleKey)
        case .a: return (0, 0x04)
        case .b: return (0, 0x05)
        case .c: return (0, 0x06)
        case .none: return (0, 0)
        }
    }

    static func matching(mod: UInt8, key: UInt8) -> HIDKeyPresets {
        allCases.first { $0.modKey == (mod, key) } ?? (key == 0 ? .none : .enter)
    }
}
