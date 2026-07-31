import Foundation

/// Everything the run needs is fixed here so it cannot be misconfigured.
enum SweepConfig {
    static let deviceName = "LGE MR25GA"
    static let writeTarget = "FFF2"

    /// Empty ones (FFD5/FFE1/FFE2) are optional and skipped after timeouts.
    /// HID 1812 is invisible to CoreBluetooth (FINDINGS §3 experiment A) — skip.
    static let probeShorts = ["FFF1", "FFD2", "FFD3", "FFD4", "FFE0", "FFD5", "FFE1", "FFE2"]
    static let requiredProbeShorts = ["FFF1", "FFD2", "FFD3", "FFD4", "FFE0"]

    static let reconnectDelaySeconds = 3.0
    /// Wait for each ATT read/write response before issuing the next one.
    static let perOpTimeoutSeconds = 0.55
    static let settleAfterBurstSeconds = 0.2
    /// Enough writes to fit the remaining ~1s budget with serialized ACK waits.
    static let writesPerConnection = 2
}

@MainActor
final class HandshakeEngine: ObservableObject {
    enum Phase: String {
        case idle
        case probing
        case valueSweep
        case finished
    }

    @Published private(set) var running = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var candidateIndex = 0
    @Published private(set) var responseCount = 0
    @Published private(set) var probeSummary = ""
    @Published private(set) var probeShortIndex = 0

    weak var host: BLEHost?
    private var writeIssuedForConnection = false
    private var candidatesSentThisConnection = 0
    private var lastSentDescription: String?
    private var observationTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var opContinuation: CheckedContinuation<(success: Bool, error: String?), Never>?
    /// Invalidates stale timeout tasks so a late timer cannot steal the next op.
    private var opGeneration = 0

    private var probeValues: [String: Data] = [:]
    private var probeFailures: [String: Int] = [:]
    private var valueCandidates: [(label: String, data: Data)] = []

    var progress: String {
        guard running else {
            if responseCount > 0 { return "Stopped after a response" }
            return phase == .finished ? "Finished" : "Idle"
        }
        switch phase {
        case .probing:
            let short = probeShortIndex < SweepConfig.probeShorts.count
                ? SweepConfig.probeShorts[probeShortIndex] : "?"
            return "Probe \(short) (\(probeValues.count)/\(SweepConfig.probeShorts.count))"
        case .valueSweep:
            return "FFF2 \(candidateIndex)/\(valueCandidates.count)"
        default:
            return phase.rawValue
        }
    }

    func start() {
        guard let host else { return }
        guard !running else { return }
        cancelPendingWork()
        running = true
        phase = .probing
        candidateIndex = 0
        probeShortIndex = 0
        responseCount = 0
        writeIssuedForConnection = false
        lastSentDescription = nil
        probeValues.removeAll()
        probeFailures.removeAll()
        valueCandidates.removeAll()
        probeSummary = ""
        host.log(.matrix, "RUN started: D0FF probe → FFF2 writes (HID 1812 skipped — CB cannot see it)")
        if host.currentPeripheral != nil {
            host.disconnect(reason: "run start")
        } else {
            host.startScan(autoConnectName: SweepConfig.deviceName)
        }
    }

    func stop() {
        cancelPendingWork()
        running = false
        phase = .idle
        host?.stopScan()
        host?.log(.matrix, "RUN stopped")
    }

    func noteNotify(hex: String, characteristic: String) {
        guard running, phase == .valueSweep else { return }
        responseCount += 1
        host?.log(.matrix, "RESPONSE on \(characteristic): [\(hex)] — last write was \(lastSentDescription ?? "unknown")")
        cancelPendingWork()
        running = false
        phase = .finished
        host?.log(.matrix, "RUN stopped so the link and the log stay put.")
    }

    func noteProbeRead(shortUUID: String, data: Data) {
        guard running, phase == .probing else { return }
        probeValues[shortUUID] = data
        host?.log(.matrix, "PROBE \(shortUUID) len=\(data.count) hex=[\(data.hexString)]")
        finishPendingOp(success: true, error: nil)
    }

    func noteWriteResult(shortUUID: String, success: Bool, error: String?) {
        guard running, shortUUID.uppercased() == SweepConfig.writeTarget else { return }
        if success {
            host?.log(.matrix, "FFF2 ACK \(lastSentDescription ?? "")")
        } else {
            host?.log(.matrix, "FFF2 NAK \(lastSentDescription ?? ""): \(error ?? "unknown")")
        }
        finishPendingOp(success: success, error: error)
    }

    func ready() {
        guard let host, running else { return }
        guard !writeIssuedForConnection else { return }
        writeIssuedForConnection = true
        host.sessionState = .testing

        switch phase {
        case .probing:
            observationTask?.cancel()
            observationTask = Task { await self.runProbeSession(on: host) }
        case .valueSweep:
            observationTask?.cancel()
            observationTask = Task { await self.runValueSession(on: host) }
        default:
            break
        }
    }

    func disconnected() {
        guard running, let host else { return }
        observationTask?.cancel()
        observationTask = nil
        finishPendingOp(success: false, error: "disconnected")
        writeIssuedForConnection = false
        candidatesSentThisConnection = 0

        switch phase {
        case .probing:
            // Continue probing across connections until every short is attempted.
            if probeShortIndex >= SweepConfig.probeShorts.count {
                finishProbe(host: host)
                return
            }
        case .valueSweep:
            if candidateIndex >= valueCandidates.count {
                finish()
                return
            }
        default:
            return
        }

        scheduleReconnect(host)
    }

    private func runProbeSession(on host: BLEHost) async {
        host.log(.matrix, "Probe session from index \(probeShortIndex)")
        while running, phase == .probing, probeShortIndex < SweepConfig.probeShorts.count {
            if hasRequiredProbe() && probeShortIndex >= SweepConfig.requiredProbeShorts.count {
                host.log(.matrix, "Required probe complete; skipping optional empty tails")
                probeShortIndex = SweepConfig.probeShorts.count
                break
            }

            let short = SweepConfig.probeShorts[probeShortIndex]
            if probeValues[short] != nil {
                probeShortIndex += 1
                continue
            }
            guard host.characteristic(shortUUID: short) != nil else {
                host.log(.error, "Probe skip \(short): not discovered")
                probeShortIndex += 1
                continue
            }
            guard host.read(shortUUID: short, tag: "probe") else {
                probeShortIndex += 1
                continue
            }
            let result = await waitForOp()
            if result.success {
                probeShortIndex += 1
                continue
            }

            let fails = (probeFailures[short] ?? 0) + 1
            probeFailures[short] = fails
            let required = SweepConfig.requiredProbeShorts.contains(short)
            if !required || fails >= 3 {
                host.log(.error, "Probe give up on \(short) after \(fails) timeout(s)")
                probeValues[short] = Data()
                probeShortIndex += 1
                continue
            }
            break
        }

        if probeShortIndex >= SweepConfig.probeShorts.count ||
            (hasRequiredProbe() && probeShortIndex >= SweepConfig.requiredProbeShorts.count) {
            probeShortIndex = SweepConfig.probeShorts.count
            host.disconnect(reason: "probe complete")
        } else {
            host.disconnect(reason: "probe partial, continue next connection")
        }
    }

    private func hasRequiredProbe() -> Bool {
        SweepConfig.requiredProbeShorts.allSatisfy { probeValues[$0] != nil }
    }

    private func finishProbe(host: BLEHost) {
        let lines = SweepConfig.probeShorts.map { short -> String in
            if let data = probeValues[short] {
                return "\(short)=\(data.count)b[\(data.hexString)]"
            }
            return "\(short)=missing"
        }
        probeSummary = lines.joined(separator: " ")
        host.log(.matrix, "Probe done: \(probeSummary)")

        valueCandidates = buildCandidates()
        candidateIndex = 0
        phase = .valueSweep
        host.log(.matrix, "FFF2 candidates: \(valueCandidates.count)")
        for (i, item) in valueCandidates.enumerated() {
            host.log(.matrix, "  \(i + 1). \(item.label) len=\(item.data.count) [\(item.data.hexString)]")
        }
        scheduleReconnect(host)
    }

    /// FFF1 is length-prefixed: first byte 0x0C and total length 12.
    /// FFF2 is treated as the write side of that same 12-byte record.
    private func buildCandidates() -> [(label: String, data: Data)] {
        var result: [(label: String, data: Data)] = []
        var seen = Set<Data>()

        func add(_ label: String, _ data: Data) {
            guard !seen.contains(data) else { return }
            seen.insert(data)
            result.append((label, data))
        }

        guard let fff1 = probeValues["FFF1"], fff1.count >= 1 else {
            host?.log(.error, "No FFF1; cannot build FFF2 candidates")
            return result
        }

        let declared = Int(fff1[0])
        let length = fff1.count
        host?.log(.matrix, "FFF1 declared_len=\(declared) actual_len=\(length)")

        // 1. Exact echo — baseline.
        add("echo FFF1", fff1)

        // 2. Flip / bump likely command or flags bytes (index 1 and 2).
        if length >= 3 {
            for (idx, values) in [1: [0x00, 0x01, 0x02, 0x10, 0x80, 0xFF],
                                  2: [0x00, 0x01, 0x02, 0x10, 0xFF]] as [Int: [UInt8]] {
                for v in values {
                    var m = fff1
                    m[idx] = v
                    add("FFF1[\(idx)]=\(String(format: "%02X", v))", m)
                }
            }
        }

        // 3. Last byte as simple command / status.
        if length >= 1 {
            for v: UInt8 in [0x00, 0x01, 0x02, 0x03, 0x04, 0x10, 0x80, 0xFF] {
                var m = fff1
                m[length - 1] = v
                add("FFF1[last]=\(String(format: "%02X", v))", m)
            }
        }

        // 4. Zero / ones / increment payloads of the FFF1 length only.
        add("zeros", Data(repeating: 0x00, count: length))
        add("ones", Data(repeating: 0x01, count: length))
        var counting = Data(count: length)
        for i in 0..<length { counting[i] = UInt8(i & 0xFF) }
        add("counting", counting)

        // 5. Length-prefixed shells: keep 0x0C header, clear body / set opcodes.
        if declared == length {
            var clearBody = Data(repeating: 0x00, count: length)
            clearBody[0] = UInt8(length)
            add("lenhdr+zeros", clearBody)

            for op: UInt8 in [0x01, 0x02, 0x03, 0x04, 0x10] {
                var m = clearBody
                if length > 1 { m[1] = op }
                add("lenhdr+op\(String(format: "%02X", op))", m)
            }
        }

        // 6. If other probe values arrived, splice them into the FFF1 template.
        for short in ["FFD3", "FFD4", "FFD5", "FFE1", "FFE2"] {
            guard let src = probeValues[short], !src.isEmpty else { continue }
            var m = fff1
            let n = min(src.count, length - 1)
            for i in 0..<n { m[1 + i] = src[i] }
            add("FFF1+splice \(short)", m)
        }

        if let ffe0 = probeValues["FFE0"], ffe0.count >= length {
            add("FFE0 prefix", Data(ffe0.prefix(length)))
        }

        return result
    }

    private func runValueSession(on host: BLEHost) async {
        guard host.characteristic(shortUUID: SweepConfig.writeTarget) != nil else {
            host.log(.error, "FFF2 not discovered")
            finish()
            return
        }

        let start = candidateIndex
        var sent = 0
        // One-at-a-time writes so ACK/NAK maps to the right payload.
        while running, phase == .valueSweep, candidateIndex < valueCandidates.count, sent < SweepConfig.writesPerConnection {
            let item = valueCandidates[candidateIndex]
            let number = candidateIndex + 1
            lastSentDescription = "#\(number) \(item.label)"
            host.log(.matrix, "Write FFF2 \(lastSentDescription!) [\(item.data.hexString)]")
            guard host.write(data: item.data, to: SweepConfig.writeTarget, tag: "val-\(number)", preferWithoutResponse: false) else {
                break
            }
            let result = await waitForOp()
            sent += 1
            candidatesSentThisConnection = sent
            candidateIndex += 1
            if !result.success, let error = result.error, error.localizedCaseInsensitiveContains("length") {
                host.log(.error, "Length rejected for \(item.label); remaining same-length siblings may still be valid")
            }
            // If the link is already dying, stop issuing more.
            if host.currentPeripheral == nil { break }
        }

        try? await Task.sleep(for: .seconds(SweepConfig.settleAfterBurstSeconds))
        guard running, phase == .valueSweep else { return }
        if candidateIndex >= valueCandidates.count {
            host.disconnect(reason: "value sweep complete")
        } else {
            host.disconnect(reason: "value burst \(start + 1)–\(candidateIndex) observed")
        }
    }

    private func waitForOp() async -> (success: Bool, error: String?) {
        opGeneration += 1
        let generation = opGeneration
        return await withCheckedContinuation { continuation in
            self.opContinuation = continuation
            Task {
                try? await Task.sleep(for: .seconds(SweepConfig.perOpTimeoutSeconds))
                guard generation == self.opGeneration else { return }
                self.finishPendingOp(success: false, error: "timeout")
            }
        }
    }

    private func finishPendingOp(success: Bool, error: String?) {
        guard let continuation = opContinuation else { return }
        opContinuation = nil
        opGeneration += 1
        continuation.resume(returning: (success, error))
    }

    private func scheduleReconnect(_ host: BLEHost) {
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(SweepConfig.reconnectDelaySeconds))
            guard !Task.isCancelled, self.running else { return }
            host.startScan(autoConnectName: SweepConfig.deviceName)
        }
    }

    private func finish() {
        cancelPendingWork()
        running = false
        phase = .finished
        host?.log(.matrix, "RUN finished: tried \(candidateIndex)/\(valueCandidates.count) FFF2 candidates — no A001 response")
    }

    private func cancelPendingWork() {
        observationTask?.cancel()
        observationTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        finishPendingOp(success: false, error: "cancelled")
        candidatesSentThisConnection = 0
    }
}
