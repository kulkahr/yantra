import Foundation
import ScaleKit

/// One stored measurement (SRD-003 FR-3 / SRD-004 FR-3).
/// Deduplication key: (deviceId, utc, weightKg) — official-app parity.
struct MeasurementRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var deviceId: String
    var slot: Int
    var weightKg: Double
    var impedanceOhm: Int?
    var utc: Date
    var unitRaw: Int
    var remainCount: Int

    init(deviceId: String, slot: Int, from r: A6WeightRecord) {
        self.deviceId = deviceId
        self.slot = slot
        self.weightKg = r.weightKg
        self.impedanceOhm = r.impedanceOhm
        // Scale timestamps come from the record when present (flag bit 3);
        // otherwise fall back to receive time.
        if let u = r.utc {
            self.utc = Date(timeIntervalSince1970: TimeInterval(u))
        } else if let dt = r.dateTime, dt.count == 6 {
            var c = DateComponents()
            c.year = 2000 + dt[0]; c.month = dt[1]; c.day = dt[2]
            c.hour = dt[3]; c.minute = dt[4]; c.second = dt[5]
            self.utc = Calendar(identifier: .gregorian).date(from: c) ?? Date()
        } else {
            self.utc = Date()
        }
        self.unitRaw = r.unitRaw
        self.remainCount = r.remainCount
    }
}

/// Thread-safe local JSON store (Application Support/Firefly/measurements.json).
final class MeasurementStore {
    static let shared = MeasurementStore()

    private let queue = DispatchQueue(label: "firefly.store", qos: .utility)
    private let fileURL: URL
    private var cache: [MeasurementRecord]?

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Firefly", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("measurements.json")
    }

    func loadAll() -> [MeasurementRecord] {
        queue.sync {
            if let cache { return cache }
            guard let data = try? Data(contentsOf: fileURL),
                  let recs = try? JSONDecoder().decode([MeasurementRecord].self, from: data)
            else { return [] }
            cache = recs
            return recs
        }
    }

    /// Inserts unless a (deviceId, utc±1 s, weight) duplicate exists; returns true when inserted.
    @discardableResult
    func insert(_ rec: MeasurementRecord) -> Bool {
        queue.sync {
            var all = cache ?? (try? loadLocked()) ?? []
            let dup = all.contains {
                $0.deviceId == rec.deviceId
                    && abs($0.utc.timeIntervalSince(rec.utc)) < 1.0
                    && abs($0.weightKg - rec.weightKg) < 0.005
            }
            guard !dup else { return false }
            all.append(rec)
            all.sort { $0.utc < $1.utc }
            cache = all
            persistLocked(all)
            return true
        }
    }

    func clear() {
        queue.sync {
            cache = []
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Locked helpers

    private func loadLocked() -> [MeasurementRecord]? {
        guard let data = try? Data(contentsOf: fileURL),
              let recs = try? JSONDecoder().decode([MeasurementRecord].self, from: data)
        else { return nil }
        return recs
    }

    private func persistLocked(_ recs: [MeasurementRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(recs) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Persisted bind result (device identity) — the app-side BindStore.
final class BindStore {
    struct Record: Codable {
        var deviceId: String
        var mac: String
        var slot: Int
        var firmwareVersion: String
        var boundAt: Date
        /// CBPeripheral.identifier from bind time — lets sessions reconnect via
        /// retrievePeripherals(withIdentifiers:) without scanning.
        var peripheralId: String?
    }

    static let shared = BindStore()

    private let url = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Firefly/bind.json", isDirectory: false)

    var record: Record? {
        get {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Record.self, from: data)
        }
        set {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let newValue else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(newValue) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

/// User profile (SRD-005) — pushed as `0x1001` user-info at session start and
/// used by BodyComposer. UserDefaults-backed; edits apply at next session.
final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published var sexMale: Bool {
        didSet { defaults.set(sexMale, forKey: "sexMale") }
    }
    @Published var age: Int {
        didSet { defaults.set(age, forKey: "age") }
    }
    @Published var heightCm: Double {
        didSet { defaults.set(heightCm, forKey: "heightCm") }
    }

    private let defaults = UserDefaults.standard

    init() {
        sexMale = defaults.object(forKey: "sexMale") as? Bool ?? true
        age = defaults.object(forKey: "age") as? Int ?? 33
        heightCm = defaults.object(forKey: "heightCm") as? Double ?? 175
    }

    var composerProfile: BodyComposer.Profile {
        BodyComposer.Profile(sexMale: sexMale, age: age, heightMeters: heightCm / 100)
    }

    var machineProfile: SessionStateMachine.UserProfile {
        SessionStateMachine.UserProfile(sexMale: sexMale, age: age, heightMeters: heightCm / 100)
    }
}
