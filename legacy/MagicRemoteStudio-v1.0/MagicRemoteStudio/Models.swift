import Foundation
import CoreBluetooth

struct DiscoveredDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
    let peripheral: CBPeripheral

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum LogLevel: String, Codable { case info = "INFO", tx = "TX", rx = "RX", matrix = "MATRIX", error = "ERROR" }

struct LogEntry: Identifiable, Codable {
    let id: UUID
    let time: Date
    let level: LogLevel
    let message: String

    init(level: LogLevel, message: String) {
        self.id = UUID(); self.time = Date(); self.level = level; self.message = message
    }
}

struct PacketEvent: Identifiable, Codable {
    enum Direction: String, Codable { case tx, rx }
    let id: UUID
    let timestamp: Date
    let direction: Direction
    let peripheralName: String
    let serviceUUID: String
    let characteristicUUID: String
    let hex: String
    let tag: String?

    init(direction: Direction, peripheralName: String, serviceUUID: String, characteristicUUID: String, data: Data, tag: String? = nil) {
        self.id = UUID(); self.timestamp = Date(); self.direction = direction
        self.peripheralName = peripheralName; self.serviceUUID = serviceUUID
        self.characteristicUUID = characteristicUUID; self.hex = data.hexString; self.tag = tag
    }
}

enum BLESessionState: String {
    case idle, scanning, connecting, discovering, subscribing, ready, testing, disconnecting
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

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }

    init?(hexText: String) {
        let cleaned = hexText.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var result = Data(); var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            result.append(byte); index = next
        }
        self = result
    }
}

extension CBUUID {
    var normalized: String { uuidString.uppercased() }
    func matchesShort(_ short: String) -> Bool {
        let value = normalized
        let s = short.uppercased()
        return value == s || value.contains("0000\(s)-") || value.hasSuffix(s)
    }
}
