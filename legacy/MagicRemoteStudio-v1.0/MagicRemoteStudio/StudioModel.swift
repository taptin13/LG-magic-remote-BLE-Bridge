import Foundation
import AppKit
import Combine

@MainActor
final class StudioModel: ObservableObject {
    let host = BLEHost()
    let recorder = PacketRecorder()
    let handshake = HandshakeEngine()
    var bridge = SerialBridge()
    var mapper = InputMapper()
    @Published var lastExportURL: URL?
    private var subscriptions: Set<AnyCancellable> = []

    init() {
        host.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        recorder.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        handshake.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        bridge.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        mapper.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)

        handshake.host = host
        host.onPacket = { [weak recorder, weak handshake] event, data in
            recorder?.record(event, rawData: data)
            guard event.direction == .rx else { return }
            let short = event.characteristicUUID.uppercased()
            if SweepConfig.probeShorts.contains(where: { short.hasSuffix($0) || short.contains("0000\($0)-") }) {
                let name = SweepConfig.probeShorts.first { short.hasSuffix($0) || short.contains("0000\($0)-") } ?? short
                handshake?.noteProbeRead(shortUUID: name, data: data)
                return
            }
            if short.hasSuffix("A001") || short.contains("0000A001-") {
                handshake?.noteNotify(hex: data.hexString, characteristic: event.characteristicUUID)
            }
        }
        host.onWriteResult = { [weak handshake] uuid, success, error in
            let short = uuid.uppercased()
            let name = short.hasSuffix("FFF2") || short.contains("0000FFF2-") ? "FFF2" : uuid
            handshake?.noteWriteResult(shortUUID: name, success: success, error: error)
        }
        host.onReady = { [weak handshake] in handshake?.ready() }
        host.onDisconnected = { [weak handshake] _ in handshake?.disconnected() }

        bridge.onLog = { [weak host] level, message in
            host?.log(level, message)
        }
        bridge.onHID = { [weak recorder] reportId, data in
            // Đừng ghi mọi packet IMU (~50Hz) — chỉ sample / nút
            if reportId == 0xFD && data.count >= 19 {
                let btn = UInt16(data[data.count - 3]) << 8 | UInt16(data[data.count - 2])
                if btn == 0 { return }
            }
            let event = PacketEvent(
                direction: .rx,
                peripheralName: "ESP32-bridge",
                serviceUUID: "1812",
                characteristicUUID: String(format: "2A4D/id=%02X", reportId),
                data: data,
                tag: "bridge"
            )
            recorder?.record(event, rawData: data)
        }
        bridge.onFDReport = { [weak mapper] report in
            mapper?.handle(report)
        }
        mapper.onLog = { [weak host] level, message in
            host?.log(level, message)
        }
        mapper.refreshTrust()
        bridge.refreshPorts()
    }

    func export() {
        do {
            let url = try recorder.exportJSONL()
            lastExportURL = url
            NSWorkspace.shared.activateFileViewerSelecting([url])
            host.log(.info, "Exported capture to \(url.path)")
        } catch {
            host.log(.error, "Export failed: \(error.localizedDescription)")
        }
    }
}
