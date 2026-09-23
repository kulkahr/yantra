import Foundation

/// Device kinds Firefly can host (SRD-009). Each kind is served by exactly one
/// `DeviceDriver` implementation registered in `DriverRegistry`.
public enum DeviceKind: String, Codable, CaseIterable {
    case scale
    case watch
    case bulb

    public var displayName: String {
        switch self {
        case .scale: return "Smart Scale"
        case .watch: return "Smart Watch"
        case .bulb: return "Smart Bulb"
        }
    }

    /// SF Symbol shown in the Devices hub.
    public var symbolName: String {
        switch self {
        case .scale: return "scalemass"
        case .watch: return "applewatch"
        case .bulb: return "lightbulb"
        }
    }
}

/// Normalized view of one BLE advertisement (SRD-009 §2.2) — drivers never
/// touch `CBPeripheral`/advertisement dictionaries directly.
public struct AdvertisementSnapshot: Equatable, Identifiable {
    /// Stable per-peripheral identity (dedup key for scan lists).
    public var id: UUID { peripheralId }
    public var peripheralId: UUID
    public var name: String?
    public var rssi: Int
    public var manufacturerData: Data?
    public var kind: DeviceKind

    public init(peripheralId: UUID, name: String?, rssi: Int,
                manufacturerData: Data?, kind: DeviceKind) {
        self.peripheralId = peripheralId
        self.name = name
        self.rssi = rssi
        self.manufacturerData = manufacturerData
        self.kind = kind
    }
}

/// Scans for one kind of device. The host runs a single `CBCentralManager`
/// and forwards matching `didDiscover` reports to the active scanner.
public protocol DeviceScanner: AnyObject {
    /// Called for every matching advertisement (dedup is the hub's job).
    var onFound: ((AdvertisementSnapshot) -> Void)? { get set }
    /// Starts receiving reports. May be called repeatedly.
    func start()
    /// Stops receiving reports.
    func stop()
}

/// Normalized GATT events handed to a connected device session (SRD-009 §2.2).
public enum CentralEvent {
    case connected
    case servicesDiscovered
    case characteristicsDiscovered
    case notifyEnabled(uuid: UUID)
    case valueUpdated(uuid: UUID, data: [UInt8])
    case writeCompleted(uuid: UUID, error: Bool)
    case readCompleted(uuid: UUID, data: [UInt8])
    case disconnected
}

/// One connected device: consumes normalized `CentralEvent`s. Drivers own
/// their state machines; the UI-facing published model is opaque here
/// (`AnyObject`) — the app layer casts it to the driver's `ObservableObject`.
public protocol DeviceSession: AnyObject {
    /// Driver-specific state object (app layer: an `ObservableObject`).
    var model: AnyObject { get }
    func handle(_ event: CentralEvent)
    /// Requests teardown; the hub performs the actual BLE disconnect.
    func disconnect()
}

/// Factory + metadata for one device kind (SRD-009 §2.2).
public protocol DeviceDriver: AnyObject {
    var kind: DeviceKind { get }
    var displayName: String { get }
    /// One-line description shown in the add-device flow.
    var summary: String { get }
    /// True while the driver is a documented stub (hub shows "coming soon").
    var isStub: Bool { get }
    func makeScanner() -> DeviceScanner
    /// Builds a session for a newly connected peripheral. The hub guarantees
    /// `connected` arrives as the first `CentralEvent`.
    func makeSession(advertisement: AdvertisementSnapshot) -> DeviceSession
}

/// Registry of available drivers (SRD-009 FR-2/FR-4). The hub iterates this —
/// adding a device kind never touches hub code.
public final class DriverRegistry: @unchecked Sendable {
    private var drivers: [DeviceKind: DeviceDriver] = [:]

    public init() {}

    public func register(_ driver: DeviceDriver) {
        drivers[driver.kind] = driver
    }

    public func driver(for kind: DeviceKind) -> DeviceDriver? {
        drivers[kind]
    }

    /// All registered kinds, sorted for stable hub display.
    public var allKinds: [DeviceKind] {
        drivers.keys.map { $0 }.sorted { $0.displayName < $1.displayName }
    }

    public var allDrivers: [DeviceDriver] {
        allKinds.compactMap { drivers[$0] }
    }
}
