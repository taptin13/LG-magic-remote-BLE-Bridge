import Foundation

// MARK: - Hex helpers

enum HexCode {
    static func parseUInt16(_ raw: String) -> UInt16? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            return UInt16(s.dropFirst(2), radix: 16)
        }
        return UInt16(s, radix: 16) ?? UInt16(s)
    }

    static func parseUInt8(_ raw: String) -> UInt8? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            return UInt8(s.dropFirst(2), radix: 16)
        }
        return UInt8(s, radix: 16) ?? UInt8(s)
    }

    static func format(_ value: UInt16) -> String {
        String(format: "0x%04X", value)
    }
}

// MARK: - Profile schema

struct InputDeviceProfile: Codable, Identifiable, Equatable, Hashable {
    var schemaVersion: Int
    var id: String
    var displayName: String
    var match: ProfileMatch?
    var buttons: [ProfileButton]
    var mouseBindings: ProfileMouseBindings?
    var defaultMaps: [ProfileDefaultMap]
    var pad: ProfilePad

    struct ProfileMatch: Codable, Equatable, Hashable {
        var bleNameContains: [String]?
    }

    struct ProfileButton: Codable, Equatable, Hashable {
        var code: String
        var name: String
        /// Semantic role used by mouseBindings / UI ("ok", "back", "settings", …).
        var role: String?

        var codeValue: UInt16? { HexCode.parseUInt16(code) }
    }

    struct ProfileMouseBindings: Codable, Equatable, Hashable {
        /// Role names resolved against `buttons[].role`.
        var left: String?
        var right: String?
        var back: String?
    }

    struct ProfileDefaultMap: Codable, Equatable, Hashable {
        var code: String
        var mod: UInt8
        var key: String
        var enabled: Bool

        func asKeyMapRow(name: String) -> KeyMapRow? {
            guard let c = HexCode.parseUInt16(code),
                  let k = HexCode.parseUInt8(key) else { return nil }
            return KeyMapRow(buttonCode: c, buttonName: name, mod: mod, key: k, enabled: enabled)
        }
    }

    struct ProfilePad: Codable, Equatable, Hashable {
        var sections: [PadSection]
    }

    struct PadSection: Codable, Equatable, Hashable {
        var type: String
        var title: String?
        var items: [PadItem]?
        /// dpad widget
        var up: String?
        var left: String?
        var ok: String?
        var right: String?
        var down: String?
    }

    struct PadItem: Codable, Equatable, Hashable {
        var kind: String
        var code: String?
        var title: String?
        var label: String?
        var width: Double?
        var height: Double?
        var round: Bool?
        var flat: Bool?
        var accent: String?
        /// Nested items for `vstack` / `hstack` kinds.
        var items: [PadItem]?
    }

    // MARK: Derived

    var buttonNameByCode: [UInt16: String] {
        var map: [UInt16: String] = [:]
        for b in buttons {
            if let c = b.codeValue { map[c] = b.name }
        }
        return map
    }

    var roleToCode: [String: UInt16] {
        var map: [String: UInt16] = [:]
        for b in buttons {
            if let role = b.role, let c = b.codeValue {
                map[role] = c
            }
        }
        return map
    }

    /// Resolved mouse button codes (left / right / back). Missing roles → nil.
    var resolvedMouseCodes: (left: UInt16?, right: UInt16?, back: UInt16?) {
        let roles = roleToCode
        let left = mouseBindings?.left.flatMap { roles[$0] }
        let right = mouseBindings?.right.flatMap { roles[$0] }
        let back = mouseBindings?.back.flatMap { roles[$0] }
        return (left, right, back)
    }

    func name(for code: UInt16) -> String {
        buttonNameByCode[code] ?? HexCode.format(code)
    }

    func defaultKeyMapRows() -> [KeyMapRow] {
        let names = buttonNameByCode
        var rows: [KeyMapRow] = []
        for m in defaultMaps {
            guard let c = HexCode.parseUInt16(m.code),
                  let row = m.asKeyMapRow(name: names[c] ?? name(for: c)) else { continue }
            rows.append(row)
        }
        return rows
    }

    func matches(bleName: String) -> Bool {
        guard let needles = match?.bleNameContains, !needles.isEmpty else { return false }
        return needles.contains { bleName.localizedCaseInsensitiveContains($0) }
    }
}

/// Mouse action → remote button code, applied while mouse mode is on.
struct MouseButtonBindings: Equatable {
    var left: UInt16?
    var right: UInt16?
    var back: UInt16?

    static let empty = MouseButtonBindings(left: nil, right: nil, back: nil)

    init(left: UInt16?, right: UInt16?, back: UInt16?) {
        self.left = left
        self.right = right
        self.back = back
    }

    init(from profile: InputDeviceProfile) {
        let r = profile.resolvedMouseCodes
        self.init(left: r.left, right: r.right, back: r.back)
    }
}
