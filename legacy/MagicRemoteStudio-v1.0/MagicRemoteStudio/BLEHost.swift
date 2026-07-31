import Foundation
import CoreBluetooth

@MainActor
final class BLEHost: NSObject, ObservableObject {
    static let d1ff = CBUUID(string: "0000D1FF-3C17-D293-8E48-14FE2E4DA212")
    static let d0ff = CBUUID(string: "0000D0FF-3C17-D293-8E48-14FE2E4DA212")
    /// Present on air (PacketLogger) but CoreBluetooth never returns it to apps.
    static let hid = CBUUID(string: "1812")

    /// Link usually dies ~2.3–2.7s after connect (remote goes quiet → Mac
    /// supervision timeout 720 ms). Measured independently on nRF and PacketLogger.
    static let watchdogSeconds = 2.3

    @Published private(set) var bluetoothState = "Unknown"
    @Published var sessionState: BLESessionState = .idle
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var connectedName: String?
    @Published private(set) var characteristics: [CBCharacteristic] = []
    @Published var logs: [LogEntry] = []

    var onPacket: ((PacketEvent, Data) -> Void)?
    var onReady: (() -> Void)?
    var onDisconnected: ((Error?) -> Void)?
    var onWriteResult: ((String, Bool, String?) -> Void)?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private(set) var currentPeripheral: CBPeripheral?
    private(set) var lastConnectedDeviceID: UUID?
    private(set) var lastConnectedDeviceName: String?
    private var connectStartedAt: Date?
    /// The watchdog runs from link establishment, not from the connect request,
    /// so the budget has to be measured from here or it reads ~0.5s pessimistic.
    private var connectedAt: Date?
    private var intentionalDisconnect = false
    private var readySignaledForConnection = false
    private var scanAutoConnectID: UUID?
    private var scanAutoConnectName: String?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func log(_ level: LogLevel, _ message: String) {
        logs.append(LogEntry(level: level, message: message))
        if logs.count > 3000 { logs.removeFirst(logs.count - 3000) }
    }

    func startScan(autoConnectID: UUID? = nil, autoConnectName: String? = nil) {
        guard central.state == .poweredOn else {
            log(.error, "Cannot scan while Bluetooth state is \(bluetoothState)")
            return
        }
        scanAutoConnectID = autoConnectID
        scanAutoConnectName = autoConnectName
        devices.removeAll(); peripherals.removeAll(); sessionState = .scanning

        let connected = central.retrieveConnectedPeripherals(withServices: [Self.d1ff])
        for peripheral in connected {
            addDevice(
                peripheral,
                name: peripheral.name ?? "Connected D1FF device",
                rssi: 0,
                source: "system-connected"
            )
        }

        log(.info, "Starting BLE scan (duplicates enabled); recovered \(connected.count) connected D1FF device(s)")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() {
        central.stopScan()
        scanAutoConnectID = nil
        scanAutoConnectName = nil
        if sessionState == .scanning { sessionState = .idle }
        log(.info, "Scan stopped")
    }

    func connect(_ device: DiscoveredDevice) {
        guard sessionState == .idle || sessionState == .scanning else {
            log(.info, "Ignoring duplicate connect request while state is \(sessionState.rawValue)")
            return
        }
        stopScan(); intentionalDisconnect = false; currentPeripheral = device.peripheral
        lastConnectedDeviceID = device.id
        lastConnectedDeviceName = device.name
        readySignaledForConnection = false
        characteristics.removeAll()
        device.peripheral.delegate = self; connectStartedAt = Date(); sessionState = .connecting
        log(.info, "Connecting to \(device.name)"); central.connect(device.peripheral)
    }

    func disconnect(reason: String = "user") {
        guard let p = currentPeripheral else { return }
        intentionalDisconnect = true; sessionState = .disconnecting
        log(.info, "Disconnect requested by \(reason)"); central.cancelPeripheralConnection(p)
    }

    func characteristic(shortUUID: String) -> CBCharacteristic? {
        characteristics.first { $0.uuid.matchesShort(shortUUID) }
    }

    func characteristics(matching shortUUID: String) -> [CBCharacteristic] {
        characteristics.filter { $0.uuid.matchesShort(shortUUID) }
    }

    private func addDevice(
        _ peripheral: CBPeripheral,
        name: String,
        rssi: Int,
        source: String
    ) {
        peripherals[peripheral.identifier] = peripheral
        let item = DiscoveredDevice(
            id: peripheral.identifier,
            name: name,
            rssi: rssi,
            peripheral: peripheral
        )
        if let index = devices.firstIndex(where: { $0.id == item.id }) {
            devices[index] = item
        } else {
            devices.append(item)
            devices.sort {
                if $0.name == $1.name { return $0.rssi > $1.rssi }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            log(.info, "Found \(name), RSSI \(rssi), source \(source), id \(peripheral.identifier)")
        }

        let matchesID = scanAutoConnectID == peripheral.identifier
        let matchesName = scanAutoConnectID == nil
            && scanAutoConnectName != nil
            && scanAutoConnectName == name
        if sessionState == .scanning, matchesID || matchesName {
            log(.matrix, "Auto-connecting to matrix target \(name)")
            connect(item)
        }
    }

    private func signalTransportReadyIfNeeded() {
        guard !readySignaledForConnection,
              let a001 = characteristic(shortUUID: "A001"),
              characteristic(shortUUID: "A002") != nil else { return }
        // Wait for CCCD subscribe to finish so early RX from handshake is not missed.
        if a001.properties.contains(.notify), !a001.isNotifying { return }
        readySignaledForConnection = true
        sessionState = .ready
        let elapsed = connectedAt.map { Date().timeIntervalSince($0) } ?? 0
        let remaining = Self.watchdogSeconds - elapsed
        log(.info, String(
            format: "Transport ready %.2fs into the link (A001 notify=%@); about %.2fs of watchdog budget left",
            elapsed,
            a001.isNotifying.description,
            remaining
        ))
        if remaining < 0.5 {
            log(.error, "Discovery ate the window; FFF2 writes may not get out.")
        }
        onReady?()
    }

    @discardableResult
    func write(hex: String, to shortUUID: String = "A002", tag: String? = nil, preferWithoutResponse: Bool = true) -> Bool {
        guard let data = Data(hexText: hex) else { log(.error, "Invalid hex: \(hex)"); return false }
        return write(data: data, to: shortUUID, tag: tag, preferWithoutResponse: preferWithoutResponse)
    }

    @discardableResult
    func write(data: Data, to shortUUID: String, tag: String? = nil, preferWithoutResponse: Bool = true) -> Bool {
        guard let p = currentPeripheral, p.state == .connected else { log(.error, "Cannot write: no connected peripheral"); return false }
        guard let c = characteristic(shortUUID: shortUUID) else { log(.error, "Cannot write: \(shortUUID) not discovered"); return false }
        let type: CBCharacteristicWriteType
        if preferWithoutResponse && c.properties.contains(.writeWithoutResponse) { type = .withoutResponse }
        else if c.properties.contains(.write) { type = .withResponse }
        else if c.properties.contains(.writeWithoutResponse) { type = .withoutResponse }
        else { log(.error, "Characteristic \(shortUUID) is not writable"); return false }
        p.writeValue(data, for: c, type: type)
        let event = PacketEvent(direction: .tx, peripheralName: p.name ?? "Unknown", serviceUUID: c.service?.uuid.uuidString ?? "", characteristicUUID: c.uuid.uuidString, data: data, tag: tag)
        onPacket?(event, data)
        log(.tx, "TX[\(tag ?? "manual")] \(shortUUID) len=\(data.count) type=\(type == .withoutResponse ? "withoutResponse" : "withResponse") hex=[\(data.hexString)]")
        return true
    }

    @discardableResult
    func read(shortUUID: String, tag: String? = nil) -> Bool {
        guard let p = currentPeripheral, p.state == .connected else { log(.error, "Cannot read: no connected peripheral"); return false }
        guard let c = characteristic(shortUUID: shortUUID) else { log(.error, "Cannot read: \(shortUUID) not discovered"); return false }
        guard c.properties.contains(.read) else { log(.error, "Characteristic \(shortUUID) is not readable"); return false }
        log(.info, "Read[\(tag ?? "manual")] \(shortUUID)")
        p.readValue(for: c)
        return true
    }

}

extension BLEHost: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            let label: String
            switch central.state {
            case .poweredOn: label = "Powered on"
            case .poweredOff: label = "Powered off"
            case .unauthorized: label = "Unauthorized"
            case .unsupported: label = "Unsupported"
            case .resetting: label = "Resetting"
            default: label = "Unknown"
            }
            bluetoothState = label; log(.info, "Bluetooth state: \(label)")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unnamed BLE device"
            addDevice(peripheral, name: name, rssi: RSSI.intValue, source: "advertisement")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connectedName = peripheral.name ?? "Unknown"; sessionState = .discovering
            connectedAt = Date()
            log(.info, "Connected to \(connectedName!)")
            // Skip Battery / Scan Params. HID 1812 is requested but CB never returns
            // it to third-party apps (system HID stack); kept for detection if that changes.
            log(.info, "Discovering D1FF and D0FF (also asking for HID 1812)")
            peripheral.discoverServices([Self.d1ff, Self.d0ff, Self.hid])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in log(.error, "Failed to connect: \(error?.localizedDescription ?? "unknown")"); sessionState = .idle }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let lifetime = connectStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            let linkLifetime = connectedAt.map { Date().timeIntervalSince($0) } ?? 0
            connectedAt = nil
            let reason = error?.localizedDescription ?? (intentionalDisconnect ? "intentional" : "normal")
            log(error == nil ? .info : .error, String(format: "Disconnected: link lived %.2fs (%.2fs since connect request); intentional=%@, error=%@", linkLifetime, lifetime, intentionalDisconnect.description, reason))
            if error != nil, !intentionalDisconnect, lifetime < 6 {
                log(.error, "Link died near \(Self.watchdogSeconds)s (remote quiet / supervision timeout). See FINDINGS §3 — Mac also stalls SMP after Pairing Response.")
            }
            characteristics.removeAll(); connectedName = nil; sessionState = .idle; currentPeripheral = nil
            onDisconnected?(error)
        }
    }
}

extension BLEHost: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error { log(.error, "Service discovery failed: \(error.localizedDescription)"); return }
            for service in peripheral.services ?? [] { log(.info, "Service \(service.uuid.uuidString)"); peripheral.discoverCharacteristics(nil, for: service) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error { log(.error, "Characteristic discovery failed: \(error.localizedDescription)"); return }
            if service.uuid.matchesShort("1812") {
                log(.matrix, "HID 1812 unexpectedly visible to CoreBluetooth — worth capturing")
            }
            for c in service.characteristics ?? [] {
                characteristics.append(c)
                var props: [String] = []
                if c.properties.contains(.read) { props.append("read") }
                if c.properties.contains(.write) { props.append("write") }
                if c.properties.contains(.writeWithoutResponse) { props.append("writeWithoutResponse") }
                if c.properties.contains(.notify) { props.append("notify") }
                if c.properties.contains(.indicate) { props.append("indicate") }
                log(.info, "Characteristic \(service.uuid.uuidString)/\(c.uuid.uuidString): \(props.joined(separator: ", "))")
                if c.uuid.matchesShort("A001") && c.properties.contains(.notify) {
                    sessionState = .subscribing
                    log(.info, "Auto-enabling notifications on A001")
                    peripheral.setNotifyValue(true, for: c)
                }
            }
            signalTransportReadyIfNeeded()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error { log(.error, "Notify state failed: \(error.localizedDescription)"); return }
            log(.info, "Notify \(characteristic.isNotifying ? "enabled" : "disabled") on \(characteristic.service?.uuid.uuidString ?? "")/\(characteristic.uuid.uuidString)")
            if characteristic.uuid.matchesShort("A001") && characteristic.isNotifying {
                signalTransportReadyIfNeeded()
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error { log(.error, "RX failed: \(error.localizedDescription)"); return }
            guard let data = characteristic.value else { return }
            let event = PacketEvent(direction: .rx, peripheralName: peripheral.name ?? "Unknown", serviceUUID: characteristic.service?.uuid.uuidString ?? "", characteristicUUID: characteristic.uuid.uuidString, data: data)
            onPacket?(event, data); log(.rx, "RX \(characteristic.uuid.uuidString) len=\(data.count) hex=[\(data.hexString)]")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            let short = characteristic.uuid.uuidString
            if let error {
                log(.error, "Write response failed on \(short): \(error.localizedDescription)")
                onWriteResult?(short, false, error.localizedDescription)
            } else {
                log(.info, "Write acknowledged on \(short)")
                onWriteResult?(short, true, nil)
            }
        }
    }
}
