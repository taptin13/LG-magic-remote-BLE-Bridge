import Foundation

/// Thread-safe handoff from the BLE queue to input injection.
/// Replaces a bare `nonisolated(unsafe)` callback while keeping zero MainActor hops for motion.
final class InputPacketSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((BridgePacket) -> Void)?

    func setHandler(_ handler: ((BridgePacket) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func deliver(_ packet: BridgePacket) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(packet)
    }
}
