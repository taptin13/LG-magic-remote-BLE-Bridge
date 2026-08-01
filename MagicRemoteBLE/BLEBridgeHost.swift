import Foundation
import CoreBluetooth
import Combine
import AppKit

/// Mac central → ESP32 peripheral (`MR-Proxy` custom GATT).
@MainActor
final class BLEBridgeHost: NSObject, ObservableObject {
    enum Phase: String {
        case idle, poweredOff, scanning, connecting, discovering, ready, failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var bluetoothOK = false
    @Published private(set) var bluetoothAuthLabel = "—"
    @Published private(set) var devices: [DiscoveredBridge] = []
    @Published var selectedID: UUID?
    @Published private(set) var remoteStatus = "—"
    @Published private(set) var eventCount = 0
    @Published private(set) var logs: [LogEntry] = []
    /// When on: BT On → Scan → Connect automatically (and reconnect after disconnect).
    @Published var autoConnect = true

    var onPacket: ((BridgePacket) -> Void)?
    /// Thread-safe input sink — set from MainActor, delivered from BLE queue.
    let inputSink = InputPacketSink()
    /// Called when prefs need saving (preferred UUID / autoConnect).
    var onPrefsChanged: (() -> Void)?

    private let bleQueue = DispatchQueue(label: "mr.ble", qos: .userInteractive)
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var active: CBPeripheral?
    private var eventChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?
    private var cmdChar: CBCharacteristic?
    /// `.ready` only after Event CCCD confirms (`didUpdateNotificationStateFor`).
    private var awaitingEventNotify = false
    /// Successfully connected UUID — preferred next time.
    private(set) var preferredPeripheralID: UUID?
    /// User tapped Disconnect → no auto reconnect until Reconnect/Scan.
    private var userStoppedAuto = false
    private var autoConnectScheduled = false
    private var connectingID: UUID?
    /// Bumped on every session bind/clear — stale CoreBluetooth callbacks must ignore old gens.
    private(set) var connectionGeneration: UInt64 = 0
    /// Mirrored for BLE-queue guards (written only from MainActor with session changes).
    nonisolated(unsafe) private var sessionPeripheralID: UUID?
    nonisolated(unsafe) private var sessionGeneration: UInt64 = 0
    /// Exponential reconnect backoff index (reset when `.ready`).
    private var reconnectAttempt = 0
    private static let reconnectBackoff: [TimeInterval] = [1, 2, 5, 10, 30]
    /// Keep the CoreBluetooth link warm — Sequoia often drops idle centrals (~15s)
    /// with CBError 6 when the peripheral is quiet (no button/motion notifies).
    private var linkKeepAliveTimer: Timer?

    override init() {
        super.init()
        recreateCentral(reason: "init")
    }

    func configure(preferredID: UUID?, autoConnect: Bool) {
        preferredPeripheralID = preferredID
        self.autoConnect = autoConnect
        if let preferredID { selectedID = preferredID }
    }

    /// Recreate CBCentralManager to trigger permission prompt (new bundle / after TCC reset).
    func requestBluetoothPermission() {
        disconnect(userInitiated: true)
        recreateCentral(reason: "request permission")
    }

    private func recreateCentral(reason: String) {
        refreshAuthLabel()
        log(.info, "Bluetooth auth=\(bluetoothAuthLabel) — \(reason)")
        central = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
            ]
        )
    }

    private func refreshAuthLabel() {
        switch CBCentralManager.authorization {
        case .allowedAlways: bluetoothAuthLabel = "Allowed"
        case .denied: bluetoothAuthLabel = "Denied"
        case .restricted: bluetoothAuthLabel = "Restricted"
        case .notDetermined: bluetoothAuthLabel = "NotDetermined (waiting for prompt)"
        @unknown default: bluetoothAuthLabel = "?\(CBCentralManager.authorization.rawValue)"
        }
    }

    func log(_ level: LogLevel, _ message: String) {
        logs.append(LogEntry(level: level, message: message))
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }

    func clearLogs() { logs.removeAll() }

    /// Start (or restart) auto Scan → Connect flow.
    func reconnect() {
        userStoppedAuto = false
        autoConnect = true
        reconnectAttempt = 0
        onPrefsChanged?()
        beginAutoConnect(reason: "reconnect")
    }

    /// Turning auto-connect off must also stop an in-flight scan, otherwise the radio
    /// keeps scanning forever and the UI stays stuck on "Scanning…".
    func setAutoConnect(_ on: Bool) {
        autoConnect = on
        onPrefsChanged?()
        if on {
            userStoppedAuto = false
            reconnectAttempt = 0
            beginAutoConnect(reason: "auto-connect on")
        } else {
            userStoppedAuto = true
            stopScan()
            log(.info, "Auto-connect off")
        }
    }

    func beginAutoConnect(reason: String) {
        guard bluetoothOK else { return }
        guard autoConnect, !userStoppedAuto else { return }
        switch phase {
        case .ready, .connecting, .discovering:
            return
        default:
            break
        }
        log(.matrix, "Auto-connect — \(reason)")
        startScan()
    }

    func startScan() {
        guard bluetoothOK else { return }
        devices.removeAll()
        /* Keep preferred in map if still present — CoreBluetooth may return the same object. */
        let keep = preferredPeripheralID.flatMap { peripherals[$0] }
        peripherals.removeAll()
        if let keep { peripherals[keep.identifier] = keep }
        connectingID = nil
        phase = .scanning
        log(.info, "Scanning for \(BridgeUUID.advertisedName)…")
        central.scanForPeripherals(
            withServices: [BridgeUUID.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.phase == .scanning else { return }
            self.central.scanForPeripherals(withServices: nil, options: nil)
        }
        /* Preferred not seen after 3s → connect strongest device currently visible. */
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.phase == .scanning, self.autoConnect, !self.userStoppedAuto else { return }
            guard self.connectingID == nil, self.active == nil else { return }
            guard let best = self.devices.max(by: { $0.rssi < $1.rssi }) else { return }
            self.log(.info, "Auto-connect fallback → \(best.name) (\(best.rssi) dBm)")
            self.selectedID = best.id
            self.connectSelected()
        }
    }

    func stopScan() {
        central.stopScan()
        if phase == .scanning { phase = .idle }
    }

    func connectSelected() {
        guard let id = selectedID, let p = peripherals[id] else {
            log(.info, "No device selected — scanning…")
            beginAutoConnect(reason: "no selection")
            return
        }
        connect(peripheral: p)
    }

    private func connect(peripheral: CBPeripheral) {
        guard phase == .scanning || phase == .idle || phase == .failed else { return }
        if connectingID == peripheral.identifier { return }
        stopScan()
        bindSession(to: peripheral)
        connectingID = peripheral.identifier
        phase = .connecting
        log(.matrix, "Connecting \(peripheral.name ?? peripheral.identifier.uuidString)…")
        central.connect(peripheral, options: nil)
    }

    /// Prefer preferred UUID; otherwise pick strongest RSSI.
    private func maybeAutoConnect(to item: DiscoveredBridge) {
        guard autoConnect, !userStoppedAuto, phase == .scanning else { return }
        if let preferred = preferredPeripheralID {
            if item.id == preferred {
                selectedID = item.id
                connectSelected()
            }
            /* Different UUID — wait for preferred or timeout in startScan. */
            return
        }
        selectedID = item.id
        connectSelected()
    }

    func disconnect(userInitiated: Bool = true) {
        if userInitiated {
            userStoppedAuto = true
            log(.info, "Disconnected by user — auto-connect paused")
        }
        if let p = active { central.cancelPeripheralConnection(p) }
        clearSession(phase: .idle)
    }

    private func bindSession(to peripheral: CBPeripheral) {
        connectionGeneration &+= 1
        active = peripheral
        selectedID = peripheral.identifier
        sessionPeripheralID = peripheral.identifier
        sessionGeneration = connectionGeneration
    }

    private func clearSession(phase next: Phase) {
        stopLinkKeepAlive()
        connectionGeneration &+= 1
        active = nil
        eventChar = nil
        statusChar = nil
        cmdChar = nil
        awaitingEventNotify = false
        connectingID = nil
        remoteStatus = "—"
        sessionPeripheralID = nil
        sessionGeneration = connectionGeneration
        phase = next
    }

    private func startLinkKeepAlive() {
        stopLinkKeepAlive()
        let t = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.linkKeepAliveTick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        linkKeepAliveTimer = t
    }

    private func stopLinkKeepAlive() {
        linkKeepAliveTimer?.invalidate()
        linkKeepAliveTimer = nil
    }

    private func linkKeepAliveTick() {
        guard phase == .ready, let p = active else {
            stopLinkKeepAlive()
            return
        }
        /* readRSSI / status read → ATT traffic so macOS does not idle-drop the link. */
        p.readRSSI()
        if let statusChar {
            p.readValue(for: statusChar)
        }
    }

    private func isCurrentPeripheral(_ peripheral: CBPeripheral) -> Bool {
        active?.identifier == peripheral.identifier
    }

    nonisolated private func isSessionPeripheral(_ peripheral: CBPeripheral) -> Bool {
        sessionPeripheralID == peripheral.identifier
    }

    private func scheduleAutoReconnect() {
        guard autoConnect, !userStoppedAuto, bluetoothOK else { return }
        guard !autoConnectScheduled else { return }
        autoConnectScheduled = true
        let idx = min(reconnectAttempt, Self.reconnectBackoff.count - 1)
        let delay = Self.reconnectBackoff[idx]
        reconnectAttempt += 1
        log(.info, "Auto-reconnect in \(Int(delay))s (attempt \(reconnectAttempt))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.autoConnectScheduled = false
            self.beginAutoConnect(reason: "after disconnect")
        }
    }

    private func resetReconnectBackoff() {
        reconnectAttempt = 0
    }

    func sendCommand(_ bytes: [UInt8]) {
        guard let p = active, let c = cmdChar, !bytes.isEmpty else { return }
        /* .withResponse: surface errors when CMD requires encryption (pairing not finished). */
        p.writeValue(Data(bytes), for: c, type: .withResponse)
    }

    private func rememberPreferred(_ id: UUID) {
        preferredPeripheralID = id
        selectedID = id
        onPrefsChanged?()
    }
}

extension BLEBridgeHost: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            refreshAuthLabel()
            switch central.state {
            case .poweredOn:
                bluetoothOK = true
                if phase != .ready && phase != .connecting && phase != .discovering {
                    phase = .idle
                }
                log(.ok, "Bluetooth: Powered on")
                if autoConnect && !userStoppedAuto {
                    beginAutoConnect(reason: "bluetooth on")
                }
            case .unauthorized:
                bluetoothOK = false
                phase = .poweredOff
                log(.error, "Bluetooth: Unauthorized — allow MagicRemoteBLE in Privacy → Bluetooth")
            case .poweredOff:
                bluetoothOK = false
                phase = .poweredOff
                log(.info, "Bluetooth: Powered off")
            case .unsupported:
                bluetoothOK = false
                phase = .failed
                log(.error, "Bluetooth: Unsupported on this Mac")
            case .resetting:
                bluetoothOK = false
                log(.info, "Bluetooth: Resetting…")
            case .unknown:
                bluetoothOK = false
                log(.info, "Bluetooth: Unknown (waiting… auth=\(bluetoothAuthLabel))")
            @unknown default:
                bluetoothOK = false
                phase = .poweredOff
                log(.info, "Bluetooth: state=\(central.state.rawValue) auth=\(bluetoothAuthLabel)")
            }
        }
    }

    /// Open System Settings → Privacy → Bluetooth.
    func openBluetoothPrivacySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Bluetooth",
        ]
        for s in urls {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        let hasService = ((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? [])
            .contains(where: { $0 == BridgeUUID.service })
        guard name.contains("MR-Proxy") || name.contains("MR-BLE") || name == BridgeUUID.advertisedName || hasService else { return }

        Task { @MainActor in
            peripherals[peripheral.identifier] = peripheral
            let item = DiscoveredBridge(
                id: peripheral.identifier,
                name: name.isEmpty ? BridgeUUID.advertisedName : name,
                rssi: RSSI.intValue
            )
            if let idx = devices.firstIndex(where: { $0.id == item.id }) {
                devices[idx] = item
            } else {
                devices.append(item)
                log(.info, "Found \(item.name) rssi=\(item.rssi)")
            }
            if selectedID == nil { selectedID = item.id }
            maybeAutoConnect(to: item)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else {
                log(.info, "Ignoring stale didConnect for \(peripheral.identifier.uuidString.prefix(8))")
                return
            }
            phase = .discovering
            log(.info, "Connected — discovering MR-Proxy service")
            peripheral.delegate = self
            peripheral.discoverServices([BridgeUUID.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            guard connectingID == peripheral.identifier || isCurrentPeripheral(peripheral) else { return }
            let ns = error as NSError?
            let msg = error?.localizedDescription ?? "?"
            log(.error, "Connect failed: \(msg)")
            // CBError.peerRemovedPairingInformation == 14
            if ns?.domain == CBError.errorDomain, ns?.code == 14 {
                log(.error, "Bond Mac↔ESP mismatched (often after reflash). Bluetooth → Forget MR-Proxy, then Reconnect.")
                preferredPeripheralID = nil
                onPrefsChanged?()
            }
            clearSession(phase: .failed)
            scheduleAutoReconnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) || connectingID == peripheral.identifier else { return }
            let unexpected = error != nil || !userStoppedAuto
            log(.info, "Disconnected \(error?.localizedDescription ?? "")")
            clearSession(phase: .idle)
            if unexpected {
                scheduleAutoReconnect()
            }
        }
    }
}

extension BLEBridgeHost: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }
            if let error {
                log(.error, "Services: \(error.localizedDescription)")
                phase = .failed
                scheduleAutoReconnect()
                return
            }
            guard let svc = peripheral.services?.first(where: { $0.uuid == BridgeUUID.service }) else {
                log(.error, "Proxy service missing")
                phase = .failed
                scheduleAutoReconnect()
                return
            }
            peripheral.discoverCharacteristics(
                [BridgeUUID.event, BridgeUUID.status, BridgeUUID.command, BridgeUUID.hid],
                for: svc
            )
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }
            if let error {
                log(.error, "Chars: \(error.localizedDescription)")
                phase = .failed
                scheduleAutoReconnect()
                return
            }
            var wantEvent = false
            for c in service.characteristics ?? [] {
                if c.uuid == BridgeUUID.event || c.uuid == BridgeUUID.hid {
                    eventChar = c
                    wantEvent = true
                    peripheral.setNotifyValue(true, for: c)
                } else if c.uuid == BridgeUUID.status {
                    statusChar = c
                    peripheral.setNotifyValue(true, for: c)
                    peripheral.readValue(for: c)
                } else if c.uuid == BridgeUUID.command {
                    cmdChar = c
                }
            }
            guard wantEvent else {
                log(.error, "Event characteristic missing")
                phase = .failed
                scheduleAutoReconnect()
                return
            }
            awaitingEventNotify = true
            phase = .discovering
            log(.info, "Enabling Event notify…")
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }
            if let error {
                log(.error, "Notify \(characteristic.uuid): \(error.localizedDescription)")
                if characteristic.uuid == BridgeUUID.event || characteristic.uuid == BridgeUUID.hid {
                    awaitingEventNotify = false
                    phase = .failed
                    scheduleAutoReconnect()
                }
                return
            }
            guard characteristic.uuid == BridgeUUID.event || characteristic.uuid == BridgeUUID.hid else { return }
            guard characteristic.isNotifying else {
                log(.error, "Event notify disabled")
                awaitingEventNotify = false
                if phase == .ready || phase == .discovering { phase = .failed }
                return
            }
            guard awaitingEventNotify || phase == .discovering else { return }
            awaitingEventNotify = false
            rememberPreferred(peripheral.identifier)
            userStoppedAuto = false
            resetReconnectBackoff()
            phase = .ready
            startLinkKeepAlive()
            log(.matrix, "Ready — Event notify OK")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isSessionPeripheral(peripheral) else { return }
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        let uuid = characteristic.uuid
        if uuid == BridgeUUID.status {
            let st = data[0]
            Task { @MainActor in
                guard isCurrentPeripheral(peripheral) else { return }
                let label = BridgeUUID.statusLabel(st)
                let changed = remoteStatus != label
                remoteStatus = label
                /* Keepalive re-notifies the same status — do not spam the log. */
                if changed {
                    log(.info, "ESP32 status: \(remoteStatus)")
                }
            }
            return
        }
        guard uuid == BridgeUUID.event || uuid == BridgeUUID.hid else { return }
        guard let pkt = BridgePacket.parse(data) else {
            PerformanceMetrics.shared.parseError()
            return
        }
        PerformanceMetrics.shared.received(pkt)

        /* Motion: inject on BLE queue only — no MainActor hop (smoother). */
        if pkt.type == .motion {
            inputSink.deliver(pkt)
            return
        }

        if pkt.type == .button || pkt.type == .voice {
            inputSink.deliver(pkt)
        }

        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }
            if pkt.type != .motion { eventCount += 1 }
            onPacket?(pkt)
            if pkt.type == .button {
                log(.rx, pkt.buttonDown ? "BTN 0x\(String(format: "%04X", pkt.buttonCode))" : "BTN up")
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == BridgeUUID.command else { return }
        Task { @MainActor in
            guard isCurrentPeripheral(peripheral) else { return }
            if let error {
                let ns = error as NSError
                log(.error, "CMD write failed: \(error.localizedDescription)")
                if ns.domain == CBATTError.errorDomain,
                   ns.code == CBATTError.insufficientAuthentication.rawValue
                    || ns.code == CBATTError.insufficientEncryption.rawValue {
                    log(.info, "Pairing MR-Proxy — if bond fails after reflash: Forget MR-Proxy in Bluetooth settings")
                }
            }
        }
    }
}
