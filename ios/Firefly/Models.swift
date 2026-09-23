import Foundation
import ScaleKit

/// One stored measurement (SRD-003 FR-3 / SRD-004 FR-3).
/// Deduplication key: (deviceId, utc, weightKg) — official-app parity.
/// `personId` ties the record to a Person (nil = unassigned, awaiting user choice).
struct MeasurementRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var deviceId: String
    var slot: Int
    var weightKg: Double
    var impedanceOhm: Int?
    var utc: Date
    var unitRaw: Int
    var remainCount: Int
    /// Owning person; nil = unassigned (prompted for in History).
    var personId: UUID?

    init(deviceId: String, slot: Int, personId: UUID? = nil, from r: A6WeightRecord) {
        self.deviceId = deviceId
        self.slot = slot
        self.personId = personId
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
            guard let recs = loadLocked() else { return [] }
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

    /// Replaces a stored record (matched by id) — used by person assignment.
    /// Returns true when the record existed and was updated.
    @discardableResult
    func update(_ rec: MeasurementRecord) -> Bool {
        queue.sync {
            var all = cache ?? (try? loadLocked()) ?? []
            guard let i = all.firstIndex(where: { $0.id == rec.id }) else { return false }
            all[i] = rec
            cache = all
            persistLocked(all)
            return true
        }
    }

    /// Records with no owning person (the History assignment queue).
    func unassignedCount() -> Int {
        loadAll().filter { $0.personId == nil }.count
    }

    func clear() {
        queue.sync {
            cache = []
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - Locked helpers

    private func loadLocked() -> [MeasurementRecord]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // must match persistLocked
        return try? decoder.decode([MeasurementRecord].self, from: data)
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

/// A person tracked by the app — weights are assigned to one (SRD-005 multi-user).
/// `slot` is the scale's user slot used when this person is the active weigh-in
/// target (1...5; each slot must map to at most one person).
struct Person: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// Scale user slot claimed by this person (1...5).
    var slot: Int
    /// Per-person profile for the 0x1001 user-info push; nil fields fall back
    /// to the global ProfileStore values.
    var sexMale: Bool?
    var age: Int?
    var heightCm: Double?
    var createdAt: Date = Date()
}

/// Thread-safe local JSON store for people (Application Support/Firefly/people.json).
/// Mutations update the published array immediately and persist synchronously
/// (writes are tiny and rare; keeps tests/UI crash-consistent).
final class PersonStore: ObservableObject {
    static let shared = PersonStore()

    @Published private(set) var people: [Person] = []
    /// The person currently on the scale — new weigh-ins auto-assign to them.
    @Published var activePersonId: UUID?

    private let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Firefly", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("people.json")
        people = Self.load(from: fileURL)
        activePersonId = UserDefaults.standard.string(forKey: "activePersonId")
            .flatMap { UUID(uuidString: $0) }
        if activePersonId != nil && person(id: activePersonId!) == nil {
            activePersonId = nil
        }
    }

    var activePerson: Person? {
        guard let id = activePersonId else { return nil }
        return person(id: id)
    }

    func person(id: UUID?) -> Person? {
        guard let id else { return nil }
        return people.first { $0.id == id }
    }

    /// Person mapped to a scale slot (slot is 1-based; scale wire use is slot-1).
    func person(inSlot slot: Int) -> Person? {
        people.first { $0.slot == slot }
    }

    var slotsInUse: Set<Int> { Set(people.map(\.slot)) }

    /// Adds a person, claiming `preferredSlot` or — when it is taken/out of
    /// range — the lowest free slot 1...5. Returns nil when all 5 slots are in
    /// use (scale limit: one user per slot).
    @discardableResult
    func add(name: String, preferredSlot: Int? = nil) -> Person? {
        let used = slotsInUse
        let slot = preferredSlot.flatMap { !used.contains($0) && (1...5).contains($0) ? $0 : nil }
            ?? (1...5).first { !used.contains($0) }
        guard let slot else { return nil }
        let p = Person(name: name, slot: slot)
        var all = people
        all.append(p)
        all.sort { $0.slot < $1.slot }
        people = all
        persist(all)
        if activePersonId == nil { setActive(p) }
        return p
    }

    func rename(_ person: Person, to name: String) {
        mutate(person.id) { $0.name = name }
    }

    /// Sets (or clears, when nil) the per-person profile fields used in the
    /// 0x1001 user-info push.
    func updateProfile(_ person: Person, sexMale: Bool?, age: Int?, heightCm: Double?) {
        mutate(person.id) {
            $0.sexMale = sexMale
            $0.age = age
            $0.heightCm = heightCm
        }
    }

    func remove(_ person: Person) {
        var all = people
        all.removeAll { $0.id == person.id }
        people = all
        persist(all)
        if activePersonId == person.id {
            activePersonId = nil
            UserDefaults.standard.removeObject(forKey: "activePersonId")
        }
    }

    /// Marks `person` as the active weigh-in target (arms their scale slot).
    func setActive(_ person: Person) {
        activePersonId = person.id
        UserDefaults.standard.set(person.id.uuidString, forKey: "activePersonId")
    }

    private func mutate(_ id: UUID, _ change: (inout Person) -> Void) {
        var all = people
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[i])
        all.sort { $0.slot < $1.slot }
        people = all
        persist(all)
    }

    // MARK: - Disk (synchronous, atomic writes)

    private func persist(_ people: [Person]) {
        Self.persistLocked(people, to: fileURL)
    }

    private static func load(from url: URL) -> [Person] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601   // must match persistLocked
        return (try? decoder.decode([Person].self, from: data)) ?? []
    }

    private static func persistLocked(_ people: [Person], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(people) {
            try? data.write(to: url, options: .atomic)
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
