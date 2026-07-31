import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    var host = BLEBridgeHost()
    var mapper = InputMapper()

    @Published var keyMaps: [KeyMapRow] = KeyMapRow.defaults
    @Published var learnMode = false
    @Published var pendingLearnAssign: UInt16?
    @Published var lastButtonCode: UInt16 = 0
    @Published var lastButtonName = ""

    /// Airmouse — sent to ESP via CMD 0x02.
    @Published var sensitivity: Double = 0.045 {
        didSet { if !loadingPrefs { schedulePushAirmouse() } }
    }
    @Published var threshold: Double = 280 {
        didSet { if !loadingPrefs { schedulePushAirmouse() } }
    }
    @Published var softDead: Double = 28 {
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

    /// Label pending Learn (shown in UI) — empty if Learn has no label.
    var learnPromptLabel: String { pendingLearnLabel }

    /// Display name for code (from keyMaps, no hard fallback before custom).
    func displayName(for code: UInt16) -> String {
        keyMaps.first { $0.buttonCode == code }?.buttonName ?? KeyMapRow.name(for: code)
    }

    init() {
        host.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subs)
        mapper.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            self?.syncPointerOverlay()
            self?.persistMapperState()
        }.store(in: &subs)

        loadPrefs()
        pointerOverlay.size = Self.pointerHeight(for: pointerSizePreset)
        mapper.setMotionSmoothing(motionSmoothing)
        mapper.setNativeScroll(nativeScroll)
        mapper.resolveMap = { [weak self] code in
            self?.keyMaps.first { $0.buttonCode == code }
        }
        mapper.updateMaps(keyMaps)
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

        host.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }
                if phase == .ready {
                    /* Retry: CMD requires encryption — pairing may finish after notify. */
                    self.pushAirmouseWithRetry(attemptsLeft: 4)
                    self.savePrefs()
                } else {
                    self.airmousePush?.cancel()
                    self.mapper.releaseAllInputs()
                }
            }
            .store(in: &subs)

        syncPointerOverlay()
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
        host.sendCommand(bytes)
        host.log(.ok, String(format: "Airmouse sens=%.3f thresh=%.0f dead=%.0f", sensitivity, threshold, softDead))
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
        sensitivity = 0.045
        threshold = 280
        softDead = 28
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
                lastButtonName = KeyMapRow.name(for: packet.buttonCode)
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
        let name = learnedLabel.isEmpty ? KeyMapRow.name(for: code) : learnedLabel
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
        let name = keyMaps.first { $0.buttonCode == code }?.buttonName ?? KeyMapRow.name(for: code)
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
        keyMaps = KeyMapRow.defaults
        mapper.updateMaps(keyMaps)
        savePrefs()
        host.log(.ok, "Map reset to MR25GA defaults")
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

    /// Sync names and add new buttons from defaults (keep user-assigned maps).
    private func mergeDefaultKeyMapRows() {
        var byCode = Dictionary(uniqueKeysWithValues: keyMaps.map { ($0.buttonCode, $0) })
        for def in KeyMapRow.defaults {
            if var existing = byCode[def.buttonCode] {
                existing.buttonName = def.buttonName
                /* Fix Vol± if old map used wrong media key. */
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
        keyMaps = KeyMapRow.defaults.compactMap { byCode[$0.buttonCode] }
            + byCode.values
            .filter { row in !KeyMapRow.defaults.contains(where: { $0.buttonCode == row.buttonCode }) }
            .sorted { $0.buttonCode < $1.buttonCode }
        mapper.updateMaps(keyMaps)
    }

    func saveConnectionPrefs() {
        savePrefs()
    }

    private func persistMapperState() {
        guard !loadingPrefs else { return }
        let en = mapper.enabled
        let mouse = mapper.mouseMode
        guard en != lastPersistedMapEnabled || mouse != lastPersistedMouseMode else { return }
        lastPersistedMapEnabled = en
        lastPersistedMouseMode = mouse
        savePrefs()
    }

    private func savePrefs() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(keyMaps) {
            d.set(data, forKey: PrefKey.keymaps)
        }
        d.set(sensitivity, forKey: PrefKey.sens)
        d.set(threshold, forKey: PrefKey.thresh)
        d.set(softDead, forKey: PrefKey.dead)
        d.set(largePointer, forKey: PrefKey.largePointer)
        d.set(pointerSizePreset, forKey: PrefKey.pointerPreset)
        d.set(motionSmoothing, forKey: PrefKey.smooth)
        d.set(nativeScroll, forKey: PrefKey.nativeScroll)
        d.set(mapper.enabled, forKey: PrefKey.mapEnabled)
        d.set(mapper.mouseMode, forKey: PrefKey.mouseMode)
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

        if d.object(forKey: PrefKey.sens) != nil { sensitivity = d.double(forKey: PrefKey.sens) }
        if d.object(forKey: PrefKey.thresh) != nil { threshold = d.double(forKey: PrefKey.thresh) }
        if d.object(forKey: PrefKey.dead) != nil { softDead = d.double(forKey: PrefKey.dead) }
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

        if let data = d.data(forKey: PrefKey.keymaps),
           let rows = try? JSONDecoder().decode([KeyMapRow].self, from: data),
           !rows.isEmpty {
            keyMaps = rows
            mergeDefaultKeyMapRows()
        }
    }

    private enum PrefKey {
        static let keymaps = "mrble.keymaps"
        static let sens = "mrble.sens"
        static let thresh = "mrble.thresh"
        static let dead = "mrble.dead"
        static let largePointer = "mrble.largePointer"
        static let pointerPreset = "mrble.pointerPreset"
        static let smooth = "mrble.smooth"
        static let nativeScroll = "mrble.nativeScroll"
        static let mapEnabled = "mrble.mapEnabled"
        static let mouseMode = "mrble.mouseMode"
        static let autoConnect = "mrble.autoConnect"
        static let preferredPeripheral = "mrble.preferredPeripheral"
    }
}
