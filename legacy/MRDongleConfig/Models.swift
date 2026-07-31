import Foundation

enum LogLevel: String {
    case info, rx, tx, error, ok
}

struct LogEntry: Identifiable {
    let id = UUID()
    let time = Date()
    let level: LogLevel
    let message: String
}

struct KeyMapRow: Identifiable, Codable, Equatable {
    var id: String { String(format: "%04X", buttonCode) }
    var buttonCode: UInt16
    var buttonName: String
    var mod: UInt8
    var key: UInt8
    var enabled: Bool

    /// OK / Settings = chuột L/R cố định trên firmware — không remap.
    static let fixedMouseCodes: Set<UInt16> = [0x8044, 0x8043]

    var isFixedMouse: Bool { Self.fixedMouseCodes.contains(buttonCode) }

    var fixedMouseLabel: String? {
        switch buttonCode {
        case 0x8044: return "Chuột trái"
        case 0x8043: return "Chuột phải"
        default: return nil
        }
    }

    static let defaults: [KeyMapRow] = [
        .init(buttonCode: 0x8040, buttonName: "Up", mod: 0, key: 0x52, enabled: true),
        .init(buttonCode: 0x8041, buttonName: "Down", mod: 0, key: 0x51, enabled: true),
        .init(buttonCode: 0x8007, buttonName: "Left", mod: 0, key: 0x50, enabled: true),
        .init(buttonCode: 0x8006, buttonName: "Right", mod: 0, key: 0x4F, enabled: true),
        .init(buttonCode: 0x8044, buttonName: "Wheel/OK", mod: 0, key: 0, enabled: true),
        .init(buttonCode: 0x8028, buttonName: "Back", mod: 0, key: 0x29, enabled: true),
        .init(buttonCode: 0x807C, buttonName: "Home", mod: 0x08, key: 0x0B, enabled: true),
        .init(buttonCode: 0x8043, buttonName: "Settings", mod: 0, key: 0, enabled: true),
        .init(buttonCode: 0x8000, buttonName: "Ch+", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x8001, buttonName: "Ch-", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x8002, buttonName: "Vol+", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x8003, buttonName: "Vol-", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x8009, buttonName: "Mute", mod: 0, key: 0, enabled: false),
        .init(buttonCode: 0x8053, buttonName: "Guide/List", mod: 0, key: 0x2C, enabled: true),
        .init(buttonCode: 0x800B, buttonName: "Input", mod: 0, key: 0x2B, enabled: true),
    ]

    static let buttonNames: [UInt16: String] = [
        0x8000: "Ch+", 0x8001: "Ch-", 0x8099: "Sleep",
        0x8010: "0", 0x8011: "1", 0x8012: "2", 0x8013: "3", 0x8014: "4",
        0x8015: "5", 0x8016: "6", 0x8017: "7", 0x8018: "8", 0x8019: "9",
        0x8044: "Wheel/OK", 0x8053: "Guide/List", 0x8045: "Menu",
        0x8002: "Vol+", 0x8003: "Vol-", 0x8009: "Mute",
        0x808B: "Help/Voice", 0x807C: "Home", 0x8043: "Settings", 0x8028: "Back",
        0x805D: "Media", 0x800B: "Input", 0x8098: "Context Menu",
        0x8072: "Red", 0x8071: "Green", 0x8063: "Yellow",
        0x8061: "Blue", 0x8081: "Movies", 0x80B0: "Play", 0x80BA: "Pause",
        0x8040: "Up", 0x8041: "Down", 0x8006: "Right", 0x8007: "Left",
    ]

    static func name(for code: UInt16) -> String {
        buttonNames[code] ?? String(format: "0x%04X", code)
    }
}

enum HIDKeyPresets: String, CaseIterable, Identifiable {
    case enter, escape, space, up, down, left, right, tab, delete
    case cmdH, cmdComma, cmdQ, cmdW, cmdC, cmdV
    case volUp, volDown, mute
    case a, b, c, none

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
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        case .none: return "Tắt"
        }
    }

    /// HID keyboard usage. Media dùng sentinel 0xF1/F2/F3 (firmware → Consumer).
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
