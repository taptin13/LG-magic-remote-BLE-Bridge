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
        let visualDropped: UInt64
        let parseErrors: UInt64
        let sequenceGapPackets: UInt64
        let sequenceDiscontinuities: UInt64
        let avgMotionLatencyMs: Double
        let p50MotionLatencyMs: Double
        let p95MotionLatencyMs: Double
        let p99MotionLatencyMs: Double
        let maxMotionLatencyMs: Double
    }

    private let lock = NSLock()
    private var rxPackets: UInt64 = 0
    private var rxMotion: UInt64 = 0
    private var rxButtons: UInt64 = 0
    private var postedMotion: UInt64 = 0
    private var visualDropped: UInt64 = 0
    private var parseErrors: UInt64 = 0
    private var lastSequence: UInt8?
    private var sequenceGapPackets: UInt64 = 0
    private var sequenceDiscontinuities: UInt64 = 0
    private var latencySumNs: UInt64 = 0
    private var latencyMaxNs: UInt64 = 0
    private var latencySamples: UInt64 = 0
    private static let latencyWindowSize = 2048
    private var latencyWindowNs = [UInt64](repeating: 0, count: latencyWindowSize)
    private var latencyWindowCount = 0
    private var latencyWindowIndex = 0

    /// A new CoreBluetooth connection starts a new sequence-observation session.
    /// Firmware can reboot and restart its counter, which must not look like a
    /// 255-packet transport loss on the Mac.
    func beginTransportSession() {
        lock.lock()
        lastSequence = nil
        lock.unlock()
    }

    /// Returns the monotonic arrival timestamp to carry with this packet until
    /// the first visible CGEvent is actually posted.
    func received(_ packet: BridgePacket) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        rxPackets += 1
        switch packet.type {
        case .motion:
            rxMotion += 1
        case .button: rxButtons += 1
        default: break
        }
        if let last = lastSequence {
            let forward = (Int(packet.seq) - Int(last) + 256) & 0xFF
            if forward != 1 {
                sequenceDiscontinuities += 1
                if forward > 1 { sequenceGapPackets += UInt64(forward - 1) }
            }
        }
        lastSequence = packet.seq
        lock.unlock()
        return now
    }

    func parseError() {
        lock.lock(); parseErrors += 1; lock.unlock()
    }

    /// Record time-to-first-visible-event for all BLE packets represented by
    /// this CGEvent. Smoothing may merge several packets into one display step.
    func visualMotionPosted(receivedAtNs starts: [UInt64]) {
        let validStarts = starts.filter { $0 > 0 }
        guard !validStarts.isEmpty else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        for start in validStarts {
            let latency = now >= start ? now - start : 0
            latencySumNs += latency
            latencyMaxNs = max(latencyMaxNs, latency)
            latencySamples += 1
            latencyWindowNs[latencyWindowIndex] = latency
            latencyWindowIndex = (latencyWindowIndex + 1) % Self.latencyWindowSize
            latencyWindowCount = min(Self.latencyWindowSize, latencyWindowCount + 1)
        }
        lock.unlock()
    }

    func visualMotionDropped(_ count: Int = 1) {
        guard count > 0 else { return }
        lock.lock(); visualDropped += UInt64(count); lock.unlock()
    }

    func eventPosted() {
        lock.lock()
        postedMotion += 1
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let samples = max(1, latencySamples)
        let values = Array(latencyWindowNs.prefix(latencyWindowCount))
        let snapshotRxPackets = rxPackets
        let snapshotRxMotion = rxMotion
        let snapshotRxButtons = rxButtons
        let snapshotPostedMotion = postedMotion
        let snapshotVisualDropped = visualDropped
        let snapshotParseErrors = parseErrors
        let snapshotSequenceGapPackets = sequenceGapPackets
        let snapshotSequenceDiscontinuities = sequenceDiscontinuities
        let snapshotLatencySumNs = latencySumNs
        let snapshotLatencyMaxNs = latencyMaxNs
        lock.unlock()
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))
            return Double(sorted[index]) / 1_000_000
        }
        return Snapshot(rxPackets: snapshotRxPackets, rxMotion: snapshotRxMotion,
                        rxButtons: snapshotRxButtons, postedMotion: snapshotPostedMotion,
                        visualDropped: snapshotVisualDropped, parseErrors: snapshotParseErrors,
                        sequenceGapPackets: snapshotSequenceGapPackets,
                        sequenceDiscontinuities: snapshotSequenceDiscontinuities,
                        avgMotionLatencyMs: Double(snapshotLatencySumNs) / Double(samples) / 1_000_000,
                        p50MotionLatencyMs: percentile(0.50),
                        p95MotionLatencyMs: percentile(0.95),
                        p99MotionLatencyMs: percentile(0.99),
                        maxMotionLatencyMs: Double(snapshotLatencyMaxNs) / 1_000_000)
    }

    func summary() -> String {
        let s = snapshot()
        return String(format: "metrics rx=%llu motion=%llu buttons=%llu posted=%llu dropped=%llu parse_err=%llu seq_gap=%llu/%llu visual_ms avg/p50/p95/p99/max=%.2f/%.2f/%.2f/%.2f/%.2f",
                      s.rxPackets, s.rxMotion, s.rxButtons, s.postedMotion, s.visualDropped,
                      s.parseErrors, s.sequenceGapPackets, s.sequenceDiscontinuities,
                      s.avgMotionLatencyMs, s.p50MotionLatencyMs, s.p95MotionLatencyMs,
                      s.p99MotionLatencyMs, s.maxMotionLatencyMs)
    }

    func csvLine() -> String {
        let s = snapshot()
        return String(format: "%llu,%llu,%llu,%llu,%llu,%llu,%llu,%llu,%.3f,%.3f,%.3f,%.3f,%.3f",
                      s.rxPackets, s.rxMotion, s.rxButtons, s.postedMotion, s.visualDropped,
                      s.parseErrors, s.sequenceGapPackets, s.sequenceDiscontinuities,
                      s.avgMotionLatencyMs, s.p50MotionLatencyMs, s.p95MotionLatencyMs,
                      s.p99MotionLatencyMs, s.maxMotionLatencyMs)
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
