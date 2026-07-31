import Foundation

@MainActor
final class PacketRecorder: ObservableObject {
    @Published private(set) var events: [PacketEvent] = []
    @Published private(set) var decodedReports: [HIDFDReport] = []
    private let analyzer = ProtocolAnalyzer()

    func record(_ event: PacketEvent, rawData: Data) {
        events.append(event)
        if event.direction == .rx {
            decodedReports.append(contentsOf: analyzer.decodeFDReports(in: rawData))
        }
    }

    func clear() { events.removeAll(); decodedReports.removeAll() }

    func exportJSONL() throws -> URL {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let body = try events.map { String(data: try encoder.encode($0), encoding: .utf8)! }.joined(separator: "\n")
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MagicRemoteCapture-\(formatter.string(from: Date())).jsonl")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
