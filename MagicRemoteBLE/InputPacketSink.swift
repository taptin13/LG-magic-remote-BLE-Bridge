import Foundation

/// Low-overhead runtime metrics for BLE-to-CGEvent tuning.
/// Counters are lock-protected and never synchronously log per packet.
final class PerformanceMetrics: @unchecked Sendable {
    static let shared = PerformanceMetrics()

    struct Snapshot {
        let rxPackets: UInt64
        let rxMotion: UInt64
        let rxButtons: UInt64
        let postedMotion: UInt64
        let parseErrors: UInt64
        let avgMotionLatencyMs: Double
        let maxMotionLatencyMs: Double
    }

    private let lock = NSLock()
    private var rxPackets: UInt64 = 0
    private var rxMotion: UInt64 = 0
    private var rxButtons: UInt64 = 0
    private var postedMotion: UInt64 = 0
    private var parseErrors: UInt64 = 0
    private var motionLatenciesNs = [UInt64]()
    private var latencySumNs: UInt64 = 0
    private var latencyMaxNs: UInt64 = 0
    private var latencySamples: UInt64 = 0

    func received(_ packet: BridgePacket) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        rxPackets += 1
        switch packet.type {
        case .motion:
            rxMotion += 1
            if motionLatenciesNs.count >= 512 { motionLatenciesNs.removeFirst() }
            motionLatenciesNs.append(now)
        case .button: rxButtons += 1
        default: break
        }
        lock.unlock()
    }

    func parseError() {
        lock.lock(); parseErrors += 1; lock.unlock()
    }

    /// Completes exactly one sample for exactly one received motion packet.
    /// CGEvent posting can emit multiple events for one packet when smoothing
    /// is enabled, so measuring from moveMouse() over-counts and pairs samples
    /// with the wrong packet.
    func motionHandled() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if let start = motionLatenciesNs.first {
            motionLatenciesNs.removeFirst()
            let latency = now >= start ? now - start : 0
            latencySumNs += latency
            latencyMaxNs = max(latencyMaxNs, latency)
            latencySamples += 1
        }
        lock.unlock()
    }

    func eventPosted() {
        lock.lock()
        postedMotion += 1
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let samples = max(1, latencySamples)
        return Snapshot(rxPackets: rxPackets, rxMotion: rxMotion, rxButtons: rxButtons,
                        postedMotion: postedMotion, parseErrors: parseErrors,
                        avgMotionLatencyMs: Double(latencySumNs) / Double(samples) / 1_000_000,
                        maxMotionLatencyMs: Double(latencyMaxNs) / 1_000_000)
    }

    func summary() -> String {
        let s = snapshot()
        return String(format: "metrics rx=%llu motion=%llu buttons=%llu posted=%llu parse_err=%llu latency_avg=%.2fms latency_max=%.2fms",
                      s.rxPackets, s.rxMotion, s.rxButtons, s.postedMotion, s.parseErrors,
                      s.avgMotionLatencyMs, s.maxMotionLatencyMs)
    }

    func csvLine() -> String {
        let s = snapshot()
        return String(format: "%llu,%llu,%llu,%llu,%llu,%.3f,%.3f",
                      s.rxPackets, s.rxMotion, s.rxButtons, s.postedMotion,
                      s.parseErrors, s.avgMotionLatencyMs, s.maxMotionLatencyMs)
    }
}

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
