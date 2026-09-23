import Foundation
import CoreBluetooth
import ScaleKit

/// One paired device in the user's inventory (SRD-009 FR-4), persisted as
/// `devices.json`. Driver-specific state lives in the driver's own stores
/// (e.g. the scale's bind.json) keyed by `peripheralId`.
struct PairedDevice: Codable, Identifiable, Equatable {
    var id: UUID { peripheralId }
    var peripheralId: UUID
    var kind: DeviceKind
    var name: String
    var addedAt: Date
}

/// Persistent device inventory (SRD-009 §2.3) — `Application Support/Yantra/devices.json`.
@MainActor
final class DeviceStore: ObservableObject {
    static let shared = DeviceStore()

    @Published private(set) var devices: [PairedDevice] = []

    private let url: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yantra", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("devices.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([PairedDevice].self, from: data) {
            devices = decoded
        }
    }

    func upsert(_ device: PairedDevice) {
        if let i = devices.firstIndex(where: { $0.peripheralId == device.peripheralId }) {
            devices[i] = device
        } else {
            devices.append(device)
        }
        persist()
    }

    func remove(peripheralId: UUID) {
        devices.removeAll { $0.peripheralId == peripheralId }
        persist()
    }

    func device(peripheralId: UUID) -> PairedDevice? {
        devices.first { $0.peripheralId == peripheralId }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(devices) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Shared BLE transport for every driver (SRD-009 FR-3): one
/// `CBCentralManager`, one delegate. Routes scan reports to the active
/// scanner and connection events to the active session as `CentralEvent`s.
@MainActor
final class DeviceTransport: NSObject, ObservableObject {
    static let shared = DeviceTransport()

    /// The one central manager — created lazily so the app can present BT-off UI.
    private var central: CBCentralManager!
    private var scanner: DeviceScanner?
    /// The single connected session (hub model: one device at a time).
    private(set) var session: DeviceSession?
    private var pendingConnect: UUID?
    private var discovered = false

    override private init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var bluetoothOn: Bool { central.state == .poweredOn }

    // MARK: Scanning

    func scan(with driver: DeviceScanner) {
        scanner = driver
        guard bluetoothOn else { return }
        central.scanForPeripherals(withServices: nil, options: nil)
        driver.start()
    }

    func stopScan() {
        scanner?.stop()
        scanner = nil
        if central.isScanning { central.stopScan() }
    }

    // MARK: Connection

    func connect(peripheralId: UUID, session: DeviceSession) {
        self.session = session
        pendingConnect = peripheralId
        discovered = false
        if let p = central.retrievePeripherals(withIdentifiers: [peripheralId]).first {
            p.delegate = transportDelegate
            central.connect(p)
        }
    }

    func disconnect() {
        session?.handle(.disconnected)
        if let p = central.retrievePeripherals(withIdentifiers: [pendingConnect].compactMap { $0 }).first
            ?? connectedPeripheral() {
            central.cancelPeripheralConnection(p)
        }
        session = nil
        pendingConnect = nil
    }

    private func connectedPeripheral() -> CBPeripheral? {
        central.retrieveConnectedPeripherals(withServices: []).first
    }

    /// Delivers a normalized event to the active session (no-op when idle).
    fileprivate func deliver(_ event: CentralEvent) {
        session?.handle(event)
    }
}

// MARK: - CBCentralManagerDelegate

extension DeviceTransport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            guard central.state == .poweredOn, let s = self.scanner else { return }
            self.central.scanForPeripherals(withServices: nil, options: nil)
            s.start()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        Task { @MainActor in
            guard let scanner = self.scanner else { return }
            // Drivers classify; the transport just forwards raw ingredients.
            (scanner as? ScanReporter)?.report(
                peripheralId: peripheral.identifier, name: name,
                rssi: RSSI.intValue, mfg: mfg)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.pendingConnect = peripheral.identifier
            peripheral.delegate = self.transportDelegate
            self.deliver(.connected)
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.deliver(.disconnected)
            self.session = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.deliver(.disconnected)
            self.session = nil
        }
    }
}

// MARK: - CBPeripheralDelegate (normalized forwarding)

/// Bridges peripheral callbacks into the active session. Kept as a separate
/// object so `DeviceTransport` stays the only `CBCentralManagerDelegate`.
final class TransportPeripheralDelegate: NSObject, CBPeripheralDelegate {
    private(set) weak var transport: DeviceTransport?

    init(transport: DeviceTransport) {
        self.transport = transport
        super.init()
    }

    private func forward(_ event: CentralEvent) {
        Task { @MainActor in
            self.transport?.deliver(event)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { forward(.disconnected); return }
        for s in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: s)
        }
        forward(.servicesDiscovered)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        forward(.characteristicsDiscovered)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else { return }
        forward(.notifyEnabled(uuid: UUID(uuidString: characteristic.uuid.uuidString) ?? UUID()))
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Reads AND notifications both land here (issue #8 lesson).
        guard error == nil, let v = characteristic.value else { return }
        let uuid = UUID(uuidString: characteristic.uuid.uuidString) ?? UUID()
        if characteristic.properties.contains(.read) && !characteristic.isNotifying {
            forward(.readCompleted(uuid: uuid, data: [UInt8](v)))
        }
        forward(.valueUpdated(uuid: uuid, data: [UInt8](v)))
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = UUID(uuidString: characteristic.uuid.uuidString) ?? UUID()
        forward(.writeCompleted(uuid: uuid, error: error != nil))
    }
}

extension DeviceTransport {
    /// One delegate per transport, created on first use and kept for the
    /// transport's lifetime. CB stores its peripheral delegates weakly, so
    /// the transport must strongly retain the delegate; the previous
    /// static-singleton scheme had its `transport` back-reference
    /// overwritten by whichever accessor ran last, so peripheral callbacks
    /// could silently vanish. `DeviceTransport` is a singleton, so this
    /// map holds at most one entry.
    private static var delegateStorage: [ObjectIdentifier: TransportPeripheralDelegate] = [:]
    private static let delegateLock = NSLock()

    var transportDelegate: TransportPeripheralDelegate {
        Self.delegateLock.lock()
        defer { Self.delegateLock.unlock() }
        if let d = Self.delegateStorage[ObjectIdentifier(self)] {
            return d
        }
        let d = TransportPeripheralDelegate(transport: self)
        Self.delegateStorage[ObjectIdentifier(self)] = d
        return d
    }

    func isNotifying(_ uuid: UUID) -> Bool { false }
}


/// Scanner hook used by the transport to forward raw advertisement fields.
protocol ScanReporter: DeviceScanner {
    func report(peripheralId: UUID, name: String?, rssi: Int, mfg: Data?)
}

extension ScaleScanner: ScanReporter {}
extension NamePrefixScanner: ScanReporter {}
