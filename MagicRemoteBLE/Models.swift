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

// MARK: - Key mapping (MR25GA)

struct KeyMapRow: Identifiable, Codable, Equatable {
    var id: String { String(format: "%04X", buttonCode) }
    var buttonCode: UInt16
    var buttonName: String
    var mod: UInt8
    var key: UInt8
    var enabled: Bool

    /// Bảng MR25GA — Code / Maps to.
    static let defaults: [KeyMapRow] = [
        .init(buttonCode: 0x8000, buttonName: "Ch+", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x8001, buttonName: "Ch-", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x8002, buttonName: "Vol+", mod: 0, key: 0xF1, enabled: true),
        .init(buttonCode: 0x8003, buttonName: "Vol-", mod: 0, key: 0xF2, enabled: true),
        .init(buttonCode: 0x8007, buttonName: "Left", mod: 0, key: 0x50, enabled: true),
        .init(buttonCode: 0x8006, buttonName: "Right", mod: 0, key: 0x4F, enabled: true),
        .init(buttonCode: 0x8040, buttonName: "Up", mod: 0, key: 0x52, enabled: true),
        .init(buttonCode: 0x8041, buttonName: "Down", mod: 0, key: 0x51, enabled: true),
        .init(buttonCode: 0x80A1, buttonName: "Input", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x8045, buttonName: "123", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x8028, buttonName: "Back", mod: 0, key: 0x29, enabled: true),
        .init(buttonCode: 0x8043, buttonName: "Settings", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x8044, buttonName: "Wheel/OK", mod: 0, key: 0x28, enabled: true),
        .init(buttonCode: 0x80AB, buttonName: "Guide/List", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x807C, buttonName: "Home", mod: 0x08, key: 0x0B, enabled: true),
        .init(buttonCode: 0x8029, buttonName: "Help", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x8056, buttonName: "B1", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x8042, buttonName: "B2", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x8031, buttonName: "B3", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x80A3, buttonName: "B4", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x8048, buttonName: "B5", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x800C, buttonName: "B6", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x808B, buttonName: "AI", mod: 0, key: HIDKeyPresets.siriKey, enabled: true),
    ]

    static let buttonNames: [UInt16: String] = [
        0x8000: "Ch+", 0x8001: "Ch-",
        0x8002: "Vol+", 0x8003: "Vol-",
        0x8007: "Left", 0x8006: "Right",
        0x8040: "Up", 0x8041: "Down",
        0x80A1: "Input", 0x8045: "123", 0x8028: "Back",
        0x8043: "Settings", 0x8044: "Wheel/OK",
        0x80AB: "Guide/List", 0x807C: "Home",
        0x8029: "Help",
        0x8056: "B1", 0x8042: "B2", 0x8031: "B3",
        0x80A3: "B4", 0x8048: "B5", 0x800C: "B6",
        0x808B: "AI",
        0x8009: "Mute", 0x8099: "Sleep",
        0x8010: "0", 0x8011: "1", 0x8012: "2", 0x8013: "3", 0x8014: "4",
        0x8015: "5", 0x8016: "6", 0x8017: "7", 0x8018: "8", 0x8019: "9",
    ]

    static func name(for code: UInt16) -> String {
        buttonNames[code] ?? String(format: "0x%04X", code)
    }
}

enum HIDKeyPresets: String, CaseIterable, Identifiable {
    case enter, escape, space, up, down, left, right, tab, delete
    case cmdH, cmdComma, cmdQ, cmdW, cmdC, cmdV
    case volUp, volDown, mute
    case siri, mouseToggle
    case a, b, c, none

    /// Pseudo HID — không trùng usage thật.
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
        case .none: return "Tắt"
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
