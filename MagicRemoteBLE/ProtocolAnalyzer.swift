import Foundation

final class ProtocolAnalyzer {
    static let buttonNames: [UInt16: String] = [
        0x8000: "Ch+", 0x8001: "Ch-",
        0x8002: "Vol+", 0x8003: "Vol-", 0x8009: "Mute",
        0x8007: "Left", 0x8006: "Right", 0x8040: "Up", 0x8041: "Down",
        0x80A1: "Input", 0x8045: "123", 0x8028: "Back", 0x8043: "Settings", 0x8044: "Wheel/OK",
        0x80AB: "Guide/List", 0x807C: "Home", 0x8029: "Help", 0x808B: "AI",
        0x8056: "B1", 0x8042: "B2", 0x8031: "B3",
        0x80A3: "B4", 0x8048: "B5", 0x800C: "B6",
        0x8010: "0", 0x8011: "1", 0x8012: "2", 0x8013: "3", 0x8014: "4",
        0x8015: "5", 0x8016: "6", 0x8017: "7", 0x8018: "8", 0x8019: "9",
        0x8099: "Sleep", 0x805D: "Media",
    ]

    /// GATT packet: [reportId][19-byte FD payload]
    func decodeBridgePacket(_ data: Data) -> (UInt8, [HIDFDReport])? {
        guard data.count >= 2 else { return nil }
        let reportId = data[0]
        let payload = data.dropFirst()
        if reportId == 0xFD {
            return (reportId, decodeMR25GAFD(Data(payload)))
        }
        return (reportId, [])
    }

    func decodeMR25GAFD(_ data: Data) -> [HIDFDReport] {
        guard data.count >= 19 else { return [] }
        let p = [UInt8](data.prefix(19))
        var imu: [Int16] = []
        for i in 0..<6 {
            let hi = UInt16(p[4 + i * 2])
            let lo = UInt16(p[5 + i * 2])
            imu.append(Int16(bitPattern: (hi << 8) | lo))
        }
        let button = UInt16(p[16]) << 8 | UInt16(p[17])
        return [
            HIDFDReport(
                offset: 0,
                counter: UInt16(p[1]),
                unknown3: p[2],
                unknown4: p[3],
                imu: imu,
                buttonCode: button,
                buttonName: Self.buttonNames[button] ?? (button == 0 ? "Released" : String(format: "Unknown_0x%04X", button)),
                wheel: Int8(bitPattern: p[18])
            )
        ]
    }
}
