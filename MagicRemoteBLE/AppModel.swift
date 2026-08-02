import Foundation
import Combine
import AppKit

private final class MetricsWriter: @unchecked Sendable {
    fileprivate static let header =
        "timestamp,rx_packets,rx_motion,rx_buttons,posted_motion,visual_dropped,parse_errors,seq_gap_packets,seq_discontinuities,visual_latency_avg_ms,visual_latency_p50_ms,visual_latency_p95_ms,visual_latency_p99_ms,visual_latency_max_ms\n"
    fileprivate static let maxBytes: UInt64 = 5 * 1024 * 1024
    fileprivate static var headerForValidation: String { header.trimmingCharacters(in: .newlines) }
    fileprivate static var headerData: Data { header.data(using: .utf8)! }
    private let queue = DispatchQueue(label: "mr.metrics", qos: .utility)

    func append(to url: URL) {
        queue.async {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(timestamp),\(PerformanceMetrics.shared.csvLine())\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? UInt64,
               size > Self.maxBytes {
                let archive = url.deletingPathExtension().appendingPathExtension("1.csv")
                try? fm.removeItem(at: archive)
                try? fm.moveItem(at: url, to: archive)
                try? Self.headerData.write(to: url, options: .atomic)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    var host = BLEBridgeHost()
    var mapper = InputMapper()

    @Published var availableProfiles: [InputDeviceProfile] = []
    @Published var activeProfileId: String = ProfileCatalog.defaultProfileID {
        didSet {
            guard !loadingPrefs, oldValue != activeProfileId else { return }
            applyActiveProfile(loadMaps: true)
            savePrefs()
        }
    }
    @Published var keyMaps: [KeyMapRow] = []
    @Published var learnMode = false
    @Published var pendingLearnAssign: UInt16?
    @Published var lastButtonCode: UInt16 = 0
    @Published var lastButtonName = ""

    var activeProfile: InputDeviceProfile {
        ProfileCatalog.shared.resolve(id: activeProfileId)
    }
    /// Airmouse defaults + UI ranges — single source of truth.
    /// Ranges stay inside firmware clamps (sens 0.005–0.5, thresh 20–2000, dead 0–200).
    enum Airmouse {
        static let sensDefault = 0.045
        static let sensRange = 0.005...0.200
        static let threshDefault = 280.0
        static let threshRange = 20.0...1000.0
        static let deadDefault = 28.0
        static let deadRange = 0.0...100.0
        /// 0 = off, 1 = max hand-shake damping (firmware LPF + deadzone boost).
        static let tremorDefault = 0.35
        static let tremorRange = 0.0...1.0
    }

    /// Airmouse — sent to ESP via CMD 0x02.
    @Published var sensitivity: Double = Airmouse.sensDefault {
        didSet { if !loadingPrefs { schedulePushAirmouse() } }
    }
    @Published var threshold: Double = Airmouse.threshDefault {
        didSet { if !loadingPrefs { schedulePushAirmouse() } }
    }
    @Published var softDead: Double = Airmouse.deadDefault {
        didSet { if !loadingPrefs { schedulePushAirmouse() } }
    }
    /// Dampen light hand tremor while holding the remote.
    @Published var tremorReduction: Double = Airmouse.tremorDefault {
        didSet { if !loadingPrefs { schedulePushAirmouse() } }
    }

    /// webOS-style pointer + motion smoothing on Mac.
    @Published var largePointer = true {
        didSet { if !loadingPrefs { saveAirmousePrefs(); syncPointerOverlay() } }
    }
    /// 0=Small 1=Medium 2=Large — matches Pointer Size on TV.
    @Published var pointerSizePreset: Int = 1 {
        didSet {
            if !loadingPrefs {
                saveAirmousePrefs()
                pointerOverlay.size = Self.pointerHeight(for: pointerSizePreset)
                syncPointerOverlay()
            }
        }
    }
    @Published var motionSmoothing = true {
        didSet {
            if !loadingPrefs {
                saveAirmousePrefs()
                mapper.setMotionSmoothing(motionSmoothing)
            }
        }
    }
    /// macOS Natural Scrolling direction (off = Windows direction).
    @Published var nativeScroll = true {
        didSet {
            if !loadingPrefs {
                saveAirmousePrefs()
                mapper.setNativeScroll(nativeScroll)
            }
        }
    }
    /// CSV recording is diagnostic-only; counters remain available in Activity.
    @Published var diagnosticsRecording = false {
        didSet {
            guard !loadingPrefs else { return }
            savePrefs()
            if diagnosticsRecording {
                startMetricsRecording()
            } else {
                stopMetricsRecording()
            }
        }
    }

    let pointerOverlay = PointerOverlayController()

    static func pointerHeight(for preset: Int) -> CGFloat {
        switch preset {
        case 0: return 1.8   // Small
        case 2: return 4.0   // Large
        default: return 2.6  // Medium
        }
    }

    var pointerSizeLabel: String {
        switch pointerSizePreset {
        case 0: return "Small"
        case 2: return "Large"
        default: return "Medium"
        }
    }

    private var pendingLearnLabel = ""
    private var learnTimeout: AnyCancellable?
    private var subs = Set<AnyCancellable>()
    private var airmousePush: AnyCancellable?
    private var loadingPrefs = false
    private var savedMapEnabled = false
    private var savedMouseMode = false
    private var lastPersistedMapEnabled = false
    private var lastPersistedMouseMode = false
    private var metricsTimer: Timer?
    private var metricsURL: URL?
    private let metricsWriter = MetricsWriter()
    /// Keeps BLE/input responsive while the bridge is Ready without preventing
    /// macOS from entering idle system sleep.
    private var bridgeActivity: NSObjectProtocol?

    /// Label pending Learn (shown in UI) — empty if Learn has no label.
    var learnPromptLabel: String { pendingLearnLabel }

    /// Display name for code (keyMaps → active profile catalog → hex).
    func displayName(for code: UInt16) -> String {
        keyMaps.first { $0.buttonCode == code }?.buttonName
            ?? activeProfile.name(for: code)
    }

    init() {
        host.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subs)
        mapper.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            /* objectWillChange fires in willSet, so the mapper still holds the old
               values here — read them on the next hop or Mouse mode never persists. */
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.syncPointerOverlay()
                    self?.persistMapperState()
                }
            }
        }.store(in: &subs)

        ProfileCatalog.shared.reload()
        availableProfiles = ProfileCatalog.shared.profiles
        loadPrefs()
        applyActiveProfile(loadMaps: false)
        pointerOverlay.size = Self.pointerHeight(for: pointerSizePreset)
        mapper.setMotionSmoothing(motionSmoothing)
        mapper.setNativeScroll(nativeScroll)
        mapper.resolveMap = { [weak self] code in
            self?.keyMaps.first { $0.buttonCode == code }
        }
        mapper.updateMaps(keyMaps)
        if diagnosticsRecording { startMetricsRecording() }
        mapper.onRemotePointerMark = { [weak self] in
            self?.pointerOverlay.markRemoteDriving()
        }
        mapper.onRemotePointerActivity = { [weak self] in
            /* Mark sync first — avoid race where CGEvent → monitor hides overlay. */
            self?.pointerOverlay.markRemoteDriving()
            DispatchQueue.main.async { self?.pointerOverlay.noteRemoteActivity() }
        }
        host.onPacket = { [weak self] packet in
            self?.onPacket(packet)
        }
        host.onPrefsChanged = { [weak self] in
            self?.savePrefs()
        }
        let mapperRef = mapper
        host.inputSink.setHandler { packet in
            mapperRef.handle(packet)
        }
        mapper.onLog = { [weak host] level, msg in
            Task { @MainActor in
                host?.log(level, msg)
            }
        }
        mapper.refreshTrust()
        /* Restore Map / Mouse mode after loadPrefs. */
        if savedMapEnabled {
            mapper.setEnabled(true)
        }
        if savedMouseMode {
            mapper.setMouseMode(true)
        }
        mapper.reassertInputPipeline()

        /* TCC / Accessibility can lag right after launch — retry without user toggle. */
        for delay in [0.4, 1.2, 3.0] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.mapper.refreshTrust()
                self.mapper.reassertInputPipeline()
                self.syncPointerOverlay()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mapper.setAppActive(true)
                self?.mapper.refreshTrust()
                self?.mapper.reassertInputPipeline()
                self?.syncPointerOverlay()
                self?.pointerOverlay.recoverAfterDisplayChange()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mapper.setAppActive(false)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pointerOverlay.recoverAfterDisplayChange()
            }
        }
        /* Pointer scaling is a WindowServer-wide setting — always undo it on quit. */
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pointerOverlay.restoreSystemPointerSize()
                self?.updateBridgeActivity(active: false)
            }
        }

        host.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                self.updateBridgeActivity(active: phase == .ready)
                if phase == .ready {
                    /* Retry: CMD requires encryption — pairing may finish after notify. */
                    self.pushAirmouseWithRetry(attemptsLeft: 4)
                    self.savePrefs()
                    self.mapper.refreshTrust()
                    self.mapper.reassertInputPipeline()
                    self.syncPointerOverlay()
                } else {
                    self.airmousePush?.cancel()
                    self.mapper.releaseAllInputs()
                }
            }
            .store(in: &subs)

        /* Remote drop → reconnect while Mac stays Ready: status char flips
           "remote dropped" → "ready". Wake the system cursor so airmouse works
           without jiggling a physical mouse first. */
        host.$remoteStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                if status == "ready" {
                    self.mapper.reassertInputPipeline()
                } else if status == "remote dropped" || status == "scan remote"
                    || status == "remote connecting"
                {
                    self.mapper.invalidateCursorTracking()
                }
            }
            .store(in: &subs)

        NotificationCenter.default.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.mapper.refreshTrust()
                self?.mapper.reassertInputPipeline()
                self?.syncPointerOverlay()
                self?.pointerOverlay.recoverAfterDisplayChange()
                /* CoreBluetooth may retain a stale `.ready` phase after sleep;
                   force a session rebind and retry after the radio settles. */
                self?.host.recoverAfterSystemWake()
            }
        }

        syncPointerOverlay()
        updateBridgeActivity(active: host.phase == .ready)
    }

    private func updateBridgeActivity(active: Bool) {
        if active {
            if bridgeActivity == nil {
                /* Keep the accessory process responsive while allowing the Mac
                   to sleep. Cursor recovery is event-driven on the next packet. */
                bridgeActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep],
                    reason: "MagicRemoteBLE bridge Ready — receive airmouse motion"
                )
            }
        } else {
            if let bridgeActivity {
                ProcessInfo.processInfo.endActivity(bridgeActivity)
                self.bridgeActivity = nil
            }
        }
    }

    func syncPointerOverlay() {
        let on = largePointer && mapper.enabled && mapper.trusted
        pointerOverlay.size = Self.pointerHeight(for: pointerSizePreset)
        pointerOverlay.setFeatureEnabled(on)
    }

    func pushAirmouseNow() {
        airmousePush?.cancel()
        saveAirmousePrefs()
        guard host.phase == .ready else { return }
        var bytes: [UInt8] = [0x02]
        bytes += Self.floatLE(Float(sensitivity))
        bytes += Self.floatLE(Float(threshold))
        bytes += Self.floatLE(Float(softDead))
        bytes += Self.floatLE(Float(tremorReduction))
        host.sendCommand(bytes)
        host.log(.ok, String(format: "Airmouse sens=%.3f thresh=%.0f dead=%.0f tremor=%.0f%%",
                             sensitivity, threshold, softDead, tremorReduction * 100))
    }

    private func pushAirmouseWithRetry(attemptsLeft: Int) {
        pushAirmouseNow()
        guard attemptsLeft > 1 else { return }
        airmousePush?.cancel()
        airmousePush = Just(())
            .delay(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.host.phase == .ready else { return }
                self.pushAirmouseWithRetry(attemptsLeft: attemptsLeft - 1)
            }
    }

    func resetAirmouse() {
        sensitivity = Airmouse.sensDefault
        threshold = Airmouse.threshDefault
        softDead = Airmouse.deadDefault
        tremorReduction = Airmouse.tremorDefault
        pushAirmouseNow()
        host.log(.ok, "Airmouse reset to defaults")
    }

    private func schedulePushAirmouse() {
        saveAirmousePrefs()
        airmousePush?.cancel()
        airmousePush = Just(())
            .delay(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] in self?.pushAirmouseNow() }
    }

    private static func floatLE(_ v: Float) -> [UInt8] {
        var le = v.bitPattern.littleEndian
        return withUnsafeBytes(of: &le) { Array($0) }
    }

    private func onPacket(_ packet: BridgePacket) {
        if packet.type == .button {
            if packet.buttonDown {
                lastButtonCode = packet.buttonCode
                lastButtonName = displayName(for: packet.buttonCode)
                if learnMode {
                    finishLearn(code: packet.buttonCode)
                }
            } else {
                lastButtonCode = 0
                lastButtonName = "Released"
            }
        }
        /* Motion/button already injected via inputSink on BLE queue. */
    }

    func appendHint(_ msg: String) {
        host.log(.info, msg)
    }

    func logPerformanceMetrics() {
        host.log(.matrix, PerformanceMetrics.shared.summary())
    }

    private func startMetricsRecording() {
        guard metricsTimer == nil else { return }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MagicRemoteBLE", isDirectory: true)
        _ = try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("metrics.csv")
        metricsURL = url
        if fm.fileExists(atPath: url.path) {
            let firstLine = (try? String(contentsOf: url, encoding: .utf8))?
                .split(whereSeparator: { $0.isNewline }).first.map(String.init)
            let expectedHeader = MetricsWriter.headerForValidation
            if firstLine != expectedHeader {
                let stamp = Int(Date().timeIntervalSince1970)
                let archive = base.appendingPathComponent("metrics-v1-\(stamp).csv")
                if (try? fm.moveItem(at: url, to: archive)) != nil {
                    host.log(.info, "Previous metrics archived → \(archive.lastPathComponent)")
                } else {
                    host.log(.error, "Metrics schema migration failed — recording disabled")
                    metricsURL = nil
                    return
                }
            }
        }
        if !fm.fileExists(atPath: url.path) {
            _ = try? MetricsWriter.headerData.write(to: url, options: .atomic)
        }
        host.log(.info, "Metrics recording enabled → \(url.path)")
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.recordMetrics()
        }
        if let metricsTimer {
            RunLoop.main.add(metricsTimer, forMode: .common)
        }
    }

    private func stopMetricsRecording() {
        metricsTimer?.invalidate()
        metricsTimer = nil
        host.log(.info, "Metrics recording disabled")
    }

    private func recordMetrics() {
        guard let url = metricsURL else { return }
        metricsWriter.append(to: url)
    }

    func startLearn(label: String = "") {
        learnTimeout?.cancel()
        learnMode = true
        pendingLearnAssign = nil
        pendingLearnLabel = label
        host.log(.info, label.isEmpty
                 ? "Learn: press a button on the remote (Cancel or wait 20s)…"
                 : "Learn «\(label)»: press that button on the remote (Cancel or wait 20s)…")
        learnTimeout = Just(())
            .delay(for: .seconds(20), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.cancelLearn(timedOut: true)
            }
    }

    func cancelLearn(timedOut: Bool = false) {
        guard learnMode else { return }
        learnTimeout?.cancel()
        learnTimeout = nil
        learnMode = false
        let label = pendingLearnLabel
        pendingLearnLabel = ""
        host.log(.info, timedOut
                 ? "Learn timeout — cancelled\(label.isEmpty ? "" : " «\(label)»")"
                 : "Learn cancelled\(label.isEmpty ? "" : " «\(label)»")")
    }

    private func finishLearn(code: UInt16) {
        learnTimeout?.cancel()
        learnTimeout = nil
        learnMode = false
        pendingLearnAssign = code
        let learnedLabel = pendingLearnLabel
        let name = learnedLabel.isEmpty ? displayName(for: code) : learnedLabel
        pendingLearnLabel = ""
        if let idx = keyMaps.firstIndex(where: { $0.buttonCode == code }) {
            if !learnedLabel.isEmpty { keyMaps[idx].buttonName = name }
        } else {
            keyMaps.append(KeyMapRow(
                buttonCode: code,
                buttonName: name,
                mod: 0,
                key: 0x28,
                enabled: true
            ))
            keyMaps.sort { $0.buttonCode < $1.buttonCode }
        }
        lastButtonCode = code
        lastButtonName = name
        host.log(.ok, "Learned \(name) 0x\(String(format: "%04X", code)) — choose a preset")
        mapper.updateMaps(keyMaps)
        savePrefs()
    }

    func applyMap(_ row: KeyMapRow) {
        if let idx = keyMaps.firstIndex(where: { $0.buttonCode == row.buttonCode }) {
            keyMaps[idx] = row
        } else {
            keyMaps.append(row)
            keyMaps.sort { $0.buttonCode < $1.buttonCode }
        }
        let preset = HIDKeyPresets.matching(mod: row.mod, key: row.key)
        host.log(.ok, "Map \(row.buttonName) → \(row.enabled ? preset.label : "Off")")
        mapper.updateMaps(keyMaps)
        savePrefs()
    }

    func setPreset(for code: UInt16, preset: HIDKeyPresets) {
        let (mod, key) = preset.modKey
        let name = keyMaps.first { $0.buttonCode == code }?.buttonName ?? displayName(for: code)
        applyMap(KeyMapRow(
            buttonCode: code,
            buttonName: name,
            mod: mod,
            key: key,
            enabled: preset != .none
        ))
        pendingLearnAssign = nil
    }

    func resetMaps() {
        keyMaps = activeProfile.defaultKeyMapRows()
        mapper.updateMaps(keyMaps)
        savePrefs()
        host.log(.ok, "Map reset to \(activeProfile.displayName) defaults")
    }

    func selectProfile(id: String) {
        guard availableProfiles.contains(where: { $0.id == id }) else { return }
        activeProfileId = id
    }

    func reloadProfiles() {
        ProfileCatalog.shared.reload()
        availableProfiles = ProfileCatalog.shared.profiles
        applyActiveProfile(loadMaps: true)
        host.log(.info, "Profiles: \(availableProfiles.map(\.id).joined(separator: ", "))")
    }

    /// Apply catalog + mouse bindings; optionally reload keymaps for the profile.
    private func applyActiveProfile(loadMaps: Bool) {
        let profile = activeProfile
        activeProfileId = profile.id
        mapper.setMouseBindings(MouseButtonBindings(from: profile))
        if loadMaps {
            keyMaps = loadKeyMaps(for: profile.id) ?? profile.defaultKeyMapRows()
            mergeDefaultKeyMapRows()
        } else if keyMaps.isEmpty {
            keyMaps = profile.defaultKeyMapRows()
            mergeDefaultKeyMapRows()
        } else {
            mergeDefaultKeyMapRows()
        }
        mapper.updateMaps(keyMaps)
    }

    func ensureMapRow(code: UInt16, name: String) {
        guard !keyMaps.contains(where: { $0.buttonCode == code }) else { return }
        keyMaps.append(KeyMapRow(
            buttonCode: code,
            buttonName: name,
            mod: 0,
            key: 0x28,
            enabled: true
        ))
        keyMaps.sort { $0.buttonCode < $1.buttonCode }
        mapper.updateMaps(keyMaps)
        savePrefs()
    }

    /// Sync names and add new buttons from active profile defaults (keep user-assigned maps).
    private func mergeDefaultKeyMapRows() {
        let defaults = activeProfile.defaultKeyMapRows()
        var byCode = Dictionary(uniqueKeysWithValues: keyMaps.map { ($0.buttonCode, $0) })
        for def in defaults {
            if var existing = byCode[def.buttonCode] {
                existing.buttonName = def.buttonName
                /* Fix Vol± if old map used wrong media key (MR25GA legacy). */
                if def.buttonCode == 0x8002, existing.key == 0xF2 { existing.key = 0xF1 }
                if def.buttonCode == 0x8003, existing.key == 0xF1 { existing.key = 0xF2 }
                /* Default AI to Siri if not assigned. */
                if def.buttonCode == 0x808B, existing.key == 0 {
                    existing.key = HIDKeyPresets.siriKey
                    existing.enabled = true
                }
                byCode[def.buttonCode] = existing
            } else {
                byCode[def.buttonCode] = def
            }
        }
        keyMaps = defaults.compactMap { byCode[$0.buttonCode] }
            + byCode.values
            .filter { row in !defaults.contains(where: { $0.buttonCode == row.buttonCode }) }
            .sorted { $0.buttonCode < $1.buttonCode }
        mapper.updateMaps(keyMaps)
    }

    private func keymapsPrefKey(for profileId: String) -> String {
        "\(PrefKey.keymapsPrefix).\(profileId)"
    }

    private func loadKeyMaps(for profileId: String) -> [KeyMapRow]? {
        let d = UserDefaults.standard
        let key = keymapsPrefKey(for: profileId)
        if let data = d.data(forKey: key),
           let rows = try? JSONDecoder().decode([KeyMapRow].self, from: data),
           !rows.isEmpty {
            return rows
        }
        return nil
    }

    private func saveKeyMaps() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(keyMaps) {
            d.set(data, forKey: keymapsPrefKey(for: activeProfileId))
            /* Keep legacy key in sync for older builds while on default profile. */
            if activeProfileId == ProfileCatalog.defaultProfileID {
                d.set(data, forKey: PrefKey.keymapsLegacy)
            }
        }
    }

    func saveConnectionPrefs() {
        savePrefs()
    }

    private func persistMapperState() {
        guard !loadingPrefs else { return }
        /* Persist user intent, not trust-failed transient off. */
        let en = mapper.wantsEnabled
        let mouse = mapper.isMouseModeEnabled()
        guard en != lastPersistedMapEnabled || mouse != lastPersistedMouseMode else { return }
        lastPersistedMapEnabled = en
        lastPersistedMouseMode = mouse
        savePrefs()
    }

    private func savePrefs() {
        let d = UserDefaults.standard
        saveKeyMaps()
        d.set(activeProfileId, forKey: PrefKey.activeProfile)
        d.set(sensitivity, forKey: PrefKey.sens)
        d.set(threshold, forKey: PrefKey.thresh)
        d.set(softDead, forKey: PrefKey.dead)
        d.set(tremorReduction, forKey: PrefKey.tremor)
        d.set(largePointer, forKey: PrefKey.largePointer)
        d.set(pointerSizePreset, forKey: PrefKey.pointerPreset)
        d.set(motionSmoothing, forKey: PrefKey.smooth)
        d.set(nativeScroll, forKey: PrefKey.nativeScroll)
        d.set(diagnosticsRecording, forKey: PrefKey.diagnostics)
        d.set(mapper.wantsEnabled, forKey: PrefKey.mapEnabled)
        d.set(mapper.isMouseModeEnabled(), forKey: PrefKey.mouseMode)
        d.set(host.autoConnect, forKey: PrefKey.autoConnect)
        if let id = host.preferredPeripheralID {
            d.set(id.uuidString, forKey: PrefKey.preferredPeripheral)
        }
        d.synchronize()
    }

    private func saveAirmousePrefs() {
        savePrefs()
    }

    private func loadPrefs() {
        loadingPrefs = true
        defer { loadingPrefs = false }
        let d = UserDefaults.standard

        /* Clamp to slider ranges — out-of-range prefs pinned the thumb while the
         * label showed the raw value (misaligned display). */
        if d.object(forKey: PrefKey.sens) != nil {
            sensitivity = d.double(forKey: PrefKey.sens).clamped(to: Airmouse.sensRange)
        }
        if d.object(forKey: PrefKey.thresh) != nil {
            threshold = d.double(forKey: PrefKey.thresh).clamped(to: Airmouse.threshRange)
        }
        if d.object(forKey: PrefKey.dead) != nil {
            softDead = d.double(forKey: PrefKey.dead).clamped(to: Airmouse.deadRange)
        }
        if d.object(forKey: PrefKey.tremor) != nil {
            tremorReduction = d.double(forKey: PrefKey.tremor).clamped(to: Airmouse.tremorRange)
        }
        if d.object(forKey: PrefKey.largePointer) != nil {
            largePointer = d.bool(forKey: PrefKey.largePointer)
        }
        if d.object(forKey: PrefKey.pointerPreset) != nil {
            pointerSizePreset = d.integer(forKey: PrefKey.pointerPreset)
        } else if d.object(forKey: "mrble.pointerSize") != nil {
            let old = d.double(forKey: "mrble.pointerSize")
            pointerSizePreset = old < 60 ? 0 : (old > 100 ? 2 : 1)
        }
        if d.object(forKey: PrefKey.smooth) != nil {
            motionSmoothing = d.bool(forKey: PrefKey.smooth)
        }
        if d.object(forKey: PrefKey.nativeScroll) != nil {
            nativeScroll = d.bool(forKey: PrefKey.nativeScroll)
        }
        if d.object(forKey: PrefKey.diagnostics) != nil {
            diagnosticsRecording = d.bool(forKey: PrefKey.diagnostics)
        }

        savedMapEnabled = d.object(forKey: PrefKey.mapEnabled) != nil
            ? d.bool(forKey: PrefKey.mapEnabled) : false
        savedMouseMode = d.object(forKey: PrefKey.mouseMode) != nil
            ? d.bool(forKey: PrefKey.mouseMode) : false
        lastPersistedMapEnabled = savedMapEnabled
        lastPersistedMouseMode = savedMouseMode

        let auto = d.object(forKey: PrefKey.autoConnect) != nil
            ? d.bool(forKey: PrefKey.autoConnect) : true
        var preferred: UUID?
        if let s = d.string(forKey: PrefKey.preferredPeripheral) {
            preferred = UUID(uuidString: s)
        }
        host.configure(preferredID: preferred, autoConnect: auto)

        migrateLegacyKeymapsIfNeeded(defaults: d)

        if let id = d.string(forKey: PrefKey.activeProfile),
           ProfileCatalog.shared.profile(id: id) != nil {
            activeProfileId = id
        } else {
            activeProfileId = ProfileCatalog.defaultProfileID
        }

        if let rows = loadKeyMaps(for: activeProfileId) {
            keyMaps = rows
        } else {
            keyMaps = activeProfile.defaultKeyMapRows()
        }
        mergeDefaultKeyMapRows()
    }

    /// Copy legacy `mrble.keymaps` → `mrble.keymaps.lg-mr25ga` once.
    private func migrateLegacyKeymapsIfNeeded(defaults d: UserDefaults) {
        let scoped = keymapsPrefKey(for: ProfileCatalog.defaultProfileID)
        guard d.data(forKey: scoped) == nil,
              let legacy = d.data(forKey: PrefKey.keymapsLegacy),
              (try? JSONDecoder().decode([KeyMapRow].self, from: legacy)) != nil else { return }
        d.set(legacy, forKey: scoped)
        if d.string(forKey: PrefKey.activeProfile) == nil {
            d.set(ProfileCatalog.defaultProfileID, forKey: PrefKey.activeProfile)
        }
    }

    private enum PrefKey {
        static let keymapsLegacy = "mrble.keymaps"
        static let keymapsPrefix = "mrble.keymaps"
        static let activeProfile = "mrble.activeProfile"
        static let sens = "mrble.sens"
        static let thresh = "mrble.thresh"
        static let dead = "mrble.dead"
        static let tremor = "mrble.tremor"
        static let largePointer = "mrble.largePointer"
        static let pointerPreset = "mrble.pointerPreset"
        static let smooth = "mrble.smooth"
        static let nativeScroll = "mrble.nativeScroll"
        static let diagnostics = "mrble.diagnostics"
        static let mapEnabled = "mrble.mapEnabled"
        static let mouseMode = "mrble.mouseMode"
        static let autoConnect = "mrble.autoConnect"
        static let preferredPeripheral = "mrble.preferredPeripheral"
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
