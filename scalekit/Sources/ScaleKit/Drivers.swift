import Foundation

/// MAC extraction shared by scale/bulb advertisement parsers (wire fact:
/// the scale's manufacturer data carries its MAC; `BleHost.macFromMfg`).
public enum AdvertisementMAC {
    /// Lifesense-style: first 6 bytes of the manufacturer payload, reversed.
    public static func fromLifesense(_ data: Data?) -> String? {
        guard let d = data, d.count >= 6 else { return nil }
        let bytes = [UInt8](d.prefix(6).reversed())
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

// MARK: - Scale driver

/// Smart-scale driver (SRD-001…008 behind the SRD-009 interface).
public final class ScaleDriver: DeviceDriver {
    public let kind: DeviceKind = .scale
    public let displayName = "Smart Scale"
    public let summary = "realme/Lifesense body-fat scale — weigh-ins, history, composition"
    public let isStub = false

    public init() {}

    public func makeScanner() -> DeviceScanner {
        ScaleScanner()
    }

    public func makeSession(advertisement: AdvertisementSnapshot) -> DeviceSession {
        // The scale's rich machine orchestration lives in the app's
        // ScaleDeviceModel (pair/session machines, people, DFU). The hub
        // re-homes it without behavior change; the advertisement only seeds
        // identity (MAC + peripheral id).
        ScaleSessionBridge(advertisement: advertisement)
    }
}

/// Matches scale advertisements: name prefixes (`LS`, `realme Smart Scale`,
/// DFU-mode `LsD`/`LsDfu`) or the Lifesense MAC in manufacturer data.
public final class ScaleScanner: DeviceScanner {
    public var onFound: ((AdvertisementSnapshot) -> Void)?
    private var reporting = Set<UUID>()

    public init() {}

    public func start() { reporting.removeAll() }

    public func stop() { reporting.removeAll() }

    public func report(peripheralId: UUID, name: String?, rssi: Int, mfg: Data?) {
        let isDfu = (name ?? "").hasPrefix("LsD")           // SRD-007 update mode
        let isScaleName = (name ?? "").hasPrefix("LS") || (name ?? "").hasPrefix("realme")
        let mac = AdvertisementMAC.fromLifesense(mfg)
        guard isDfu || isScaleName || mac != nil else { return }
        // One report per scan pass per peripheral (hub re-upserts anyway).
        guard !reporting.contains(peripheralId) else { return }
        reporting.insert(peripheralId)
        onFound?(AdvertisementSnapshot(peripheralId: peripheralId, name: name,
                                       rssi: rssi, manufacturerData: mfg, kind: .scale))
    }
}

/// Bridges the hub's `CentralEvent`s into the scale flow. The heavy lifting
/// (pair/session state machines) stays in the app layer (`ScaleDeviceModel`),
/// which this bridge exposes as the session's model.
public final class ScaleSessionBridge: DeviceSession {
    public private(set) var model: AnyObject = NSObject()
    /// Set by the app when it wires the real ScaleDeviceModel.
    public weak var appModel: ScaleEventSink?

    public init(advertisement: AdvertisementSnapshot) {
        // The app attaches its ScaleDeviceModel (an ObservableObject) right
        // after construction via attach(model:).
    }

    /// App layer attaches its published model (cast-checked in the app).
    public func attach(model: AnyObject) {
        self.model = model
    }

    public func handle(_ event: CentralEvent) {
        appModel?.handle(event)
    }

    public func disconnect() {
        appModel?.requestDisconnect()
    }
}

/// The scale machine orchestration interface the app's model implements to
/// receive hub events (keeps ScaleKit decoupled from SwiftUI/CB types).
public protocol ScaleEventSink: AnyObject {
    func handle(_ event: CentralEvent)
    func requestDisconnect()
}

// MARK: - Watch driver (SRD-010)

/// Smart-watch driver (SRD-010): boAt Storm Call 3 family via the KaHa
/// "Leonardo" protocol over Nordic UART. The app attaches its `WatchCentral`
/// model through `WatchSessionBridge.attach(model:)` (same pattern as the
/// scale's `ScaleSessionBridge`).
public final class WatchDriver: DeviceDriver {
    public let kind: DeviceKind = .watch
    public let displayName = "Smart Watch"
    public let summary = "boAt Storm Call 3 — live heart rate, steps, history"
    public let isStub = false

    public init() {}

    public func makeScanner() -> DeviceScanner {
        WatchScanner()
    }

    public func makeSession(advertisement: AdvertisementSnapshot) -> DeviceSession {
        WatchSessionBridge(advertisement: advertisement)
    }
}

/// Matches Storm Call 3 advertisements: case-insensitive `stormcall` name
/// prefix (e.g. `stormcall_3_0610`). Falls back to the generic prefix
/// scanner's matching for other watch families later.
public final class WatchScanner: DeviceScanner {
    public var onFound: ((AdvertisementSnapshot) -> Void)?
    private var reporting = Set<UUID>()

    public init() {}

    public func start() { reporting.removeAll() }

    public func stop() { reporting.removeAll() }

    public func report(peripheralId: UUID, name: String?, rssi: Int, mfg: Data?) {
        guard let n = name, n.lowercased().contains("stormcall") else { return }
        guard !reporting.contains(peripheralId) else { return }
        reporting.insert(peripheralId)
        onFound?(AdvertisementSnapshot(peripheralId: peripheralId, name: name,
                                       rssi: rssi, manufacturerData: mfg, kind: .watch))
    }
}

/// Bridges the hub's `CentralEvent`s into the app's watch model. The
/// KaHa orchestration (subscription order, command queue, parsing) lives in
/// the app layer (`WatchCentral`), exposed here as the session's model.
public final class WatchSessionBridge: DeviceSession {
    public private(set) var model: AnyObject = NSObject()
    /// Set by the app when it wires the real WatchCentral.
    public weak var appModel: WatchEventSink?

    public init(advertisement: AdvertisementSnapshot) {
        // The app attaches its WatchCentral (an ObservableObject) right
        // after construction via attach(model:).
    }

    /// App layer attaches its published model.
    public func attach(model: AnyObject) {
        self.model = model
    }

    public func handle(_ event: CentralEvent) {
        appModel?.handle(event)
    }

    public func disconnect() {
        appModel?.requestDisconnect()
    }
}

/// The watch orchestration interface the app's model implements to receive
/// hub events (keeps ScaleKit decoupled from SwiftUI/CB types).
public protocol WatchEventSink: AnyObject {
    func handle(_ event: CentralEvent)
    func requestDisconnect()
}

// MARK: - Bulb driver (stub — SRD-011)

/// Smart-bulb driver stub (SRD-009 FR-6). Consumer bulbs are mostly
/// Telink-style `0xFFF0/0xFFE0` services or mesh — SRD-011 will pick a target.
public final class BulbDriver: DeviceDriver {
    public let kind: DeviceKind = .bulb
    public let displayName = "Smart Bulb"
    public let summary = "Lighting control — protocol TBD (SRD-011)"
    public let isStub = true

    public init() {}

    public func makeScanner() -> DeviceScanner {
        NamePrefixScanner(prefixes: ["Bulb", "Light"], kind: .bulb)
    }

    public func makeSession(advertisement: AdvertisementSnapshot) -> DeviceSession {
        StubSession(kind: .bulb, advertisement: advertisement)
    }
}

/// Generic name-prefix scanner for stub drivers.
public final class NamePrefixScanner: DeviceScanner {
    public var onFound: ((AdvertisementSnapshot) -> Void)?
    private let prefixes: [String]
    private let kind: DeviceKind

    public init(prefixes: [String], kind: DeviceKind) {
        self.prefixes = prefixes
        self.kind = kind
    }

    public func start() {}

    public func stop() {}

    public func report(peripheralId: UUID, name: String?, rssi: Int, mfg: Data?) {
        guard let n = name, prefixes.contains(where: { n.hasPrefix($0) }) else { return }
        onFound?(AdvertisementSnapshot(peripheralId: peripheralId, name: name,
                                       rssi: rssi, manufacturerData: mfg, kind: kind))
    }
}

/// Placeholder session for stub drivers — records the advertisement and
/// exposes an empty model object so the hub can show "coming soon" state.
public final class StubSession: DeviceSession {
    public let model: AnyObject = NSObject()
    public let advertisement: AdvertisementSnapshot

    public init(kind: DeviceKind, advertisement: AdvertisementSnapshot) {
        self.advertisement = advertisement
    }

    public func handle(_ event: CentralEvent) {}
    public func disconnect() {}
}
