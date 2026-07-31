import Foundation

final class ProtocolAnalyzer {
    static let buttonNames: [UInt16: String] = [
        0x8000: "Power", 0x8099: "Sleep",
        0x8010: "0", 0x8011: "1", 0x8012: "2", 0x8013: "3", 0x8014: "4",
        0x8015: "5", 0x8016: "6", 0x8017: "7", 0x8018: "8", 0x8019: "9",
        0x8044: "Wheel/OK", 0x8053: "List", 0x8045: "Menu",
        0x8002: "Volume Up", 0x8003: "Volume Down", 0x8009: "Mute",
        0x808B: "Voice", 0x807C: "Home", 0x8043: "Settings", 0x8028: "Back",
        0x80AB: "Program", 0x805D: "Media", 0x800B: "TV", 0x8098: "Context Menu",
        0x8001: "Channel Down", 0x8072: "Red", 0x8071: "Green", 0x8063: "Yellow",
        0x8061: "Blue", 0x8081: "Movies", 0x80B0: "Play", 0x80BA: "Pause",
        0x8040: "Up", 0x8041: "Down", 0x8006: "Right", 0x8007: "Left"
    ]

    /// Linux HIDRAW-style 20-byte 0xFD (report id + 19).
    func decodeFDReports(in data: Data) -> [HIDFDReport] {
        guard data.count >= 20 else { return [] }
        let bytes = [UInt8](data)
        var output: [HIDFDReport] = []
        for offset in 0...(bytes.count - 20) where bytes[offset] == 0xFD {
            let p = Array(bytes[offset..<(offset + 20)])
            guard p[3] == 0x00, p[4] == 0xFD else { continue }
            let counter = UInt16(p[1]) | (UInt16(p[2]) << 8)
            var imu: [Int16] = []
            for i in 0..<6 {
                let raw = UInt16(p[5 + i * 2]) << 8 | UInt16(p[6 + i * 2])
                imu.append(Int16(bitPattern: raw))
            }
            let button = UInt16(p[17]) << 8 | UInt16(p[18])
            output.append(HIDFDReport(
                offset: offset,
                counter: counter,
                unknown3: p[3],
                unknown4: p[4],
                imu: imu,
                buttonCode: button,
                buttonName: Self.buttonNames[button] ?? (button == 0 ? "Released" : String(format: "Unknown_0x%04X", button)),
                wheel: Int8(bitPattern: p[19])
            ))
        }
        return output
    }

    /// MR25GA ATT notification for Report 0xFD (19 bytes, no leading report-id).
    /// [0] flags, [1] counter, [2..3] markers, [4..15] 6×int16 BE IMU,
    /// [16..17] button BE, [18] wheel.
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
