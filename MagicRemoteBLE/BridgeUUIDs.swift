import CoreBluetooth
import Foundation

enum BridgeUUID {
    static let service = CBUUID(string: "6D520001-4D52-3235-4741-425249444745")
    static let event = CBUUID(string: "6D520010-4D52-3235-4741-425249444745")
    static let status = CBUUID(string: "6D520003-4D52-3235-4741-425249444745")
    static let command = CBUUID(string: "6D520012-4D52-3235-4741-425249444745")
    /// Legacy HID char (old esp32-ble-bridge) — being phased out
    static let hid = CBUUID(string: "6D520002-4D52-3235-4741-425249444745")
    static let advertisedName = "MR-Proxy"

    static func statusLabel(_ b: UInt8) -> String {
        switch b {
        case 0: return "boot"
        case 1: return "wait Mac"
        case 2: return "scan remote"
        case 3: return "remote connecting"
        case 4: return "ready"
        case 5: return "remote dropped"
        default: return "status \(b)"
        }
    }
}

struct BridgeStatusHandshake: Equatable {
    static let magic: UInt8 = 0xA5

    let protocolVersion: UInt8
    let capabilities: UInt16

    static func parse(_ data: Data) -> BridgeStatusHandshake? {
        guard data.count >= 5, data[1] == magic else { return nil }
        return BridgeStatusHandshake(
            protocolVersion: data[2],
            capabilities: UInt16(data[3]) | (UInt16(data[4]) << 8)
        )
    }
}

enum BridgePktType: UInt8 {
    case motion = 1, button = 2, battery = 3, status = 4, voice = 5
}

struct BridgePacket {
    var type: BridgePktType
    var seq: UInt8
    var dx: Int16 = 0
    var dy: Int16 = 0
    var buttons: UInt16 = 0
    var wheel: Int8 = 0
    var buttonCode: UInt16 = 0
    var buttonDown: Bool = false
    var battery: UInt8 = 0
    var status: UInt8 = 0
    /// App-local monotonic timestamp; never serialized on the BLE wire.
    var receivedAtNs: UInt64 = 0

    static func parse(_ data: Data) -> BridgePacket? {
        guard data.count >= 2, let type = BridgePktType(rawValue: data[0]) else { return nil }
        var p = BridgePacket(type: type, seq: data[1])
        switch type {
        case .motion:
            guard data.count >= 8 else { return nil }
            p.dx = Int16(bitPattern: UInt16(data[2]) | (UInt16(data[3]) << 8))
            p.dy = Int16(bitPattern: UInt16(data[4]) | (UInt16(data[5]) << 8))
            p.buttons = UInt16(data[6]) | (UInt16(data[7]) << 8)
            if data.count >= 9 { p.wheel = Int8(bitPattern: data[8]) }
        case .button:
            guard data.count >= 5 else { return nil }
            p.buttonCode = UInt16(data[2]) | (UInt16(data[3]) << 8)
            p.buttonDown = data[4] != 0
        case .battery:
            guard data.count >= 3 else { return nil }
            p.battery = data[2]
        case .status:
            guard data.count >= 3 else { return nil }
            p.status = data[2]
        case .voice:
            break
        }
        return p
    }
}
