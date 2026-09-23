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

/// Thread-safe local JSON store (Application Support/Yantra/measurements.json).
final class MeasurementStore {
    static let shared = MeasurementStore()

    private let queue = DispatchQueue(label: "firefly.store", qos: .utility)
    private let fileURL: URL
    private var cache: [MeasurementRecord]?

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yantra", isDirectory: true)
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

    /// Removes a record by id (issue #13 — delete wrongly assigned entries).
    @discardableResult
    func delete(id: UUID) -> Bool {
        queue.sync {
            var all = cache ?? (try? loadLocked()) ?? []
            let before = all.count
            all.removeAll { $0.id == id }
            guard all.count < before else { return false }
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
    /// Profile pushed as 0x1001 user-info and used for body composition
    /// (issue #3 — every person carries their own sex/age/height).
    var sexMale: Bool
    var age: Int
    var heightCm: Double
    /// Weight goal (kg) shown against the trend; nil = no goal set.
    var targetWeightKg: Double?
    var createdAt: Date = Date()

    init(id: UUID = UUID(), name: String, slot: Int, sexMale: Bool,
         age: Int, heightCm: Double, targetWeightKg: Double? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.slot = slot
        self.sexMale = sexMale
        self.age = age
        self.heightCm = heightCm
        self.targetWeightKg = targetWeightKg
        self.createdAt = createdAt
    }

    /// Backward-compatible decode: older people.json stored optional profile
    /// fields (nil = unset). Fill them from sensible defaults so existing
    /// installs keep working (issue #3 upgrade path).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        slot = try c.decode(Int.self, forKey: .slot)
        sexMale = try c.decodeIfPresent(Bool.self, forKey: .sexMale) ?? true
        age = try c.decodeIfPresent(Int.self, forKey: .age) ?? 33
        heightCm = try c.decodeIfPresent(Double.self, forKey: .heightCm) ?? 175
        targetWeightKg = try c.decodeIfPresent(Double.self, forKey: .targetWeightKg)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(slot, forKey: .slot)
        try c.encode(sexMale, forKey: .sexMale)
        try c.encode(age, forKey: .age)
        try c.encode(heightCm, forKey: .heightCm)
        try c.encodeIfPresent(targetWeightKg, forKey: .targetWeightKg)
        try c.encode(createdAt, forKey: .createdAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, slot, sexMale, age, heightCm, targetWeightKg, createdAt
    }
}

/// Thread-safe local JSON store for people (Application Support/Yantra/people.json).
/// Mutations update the published array immediately and persist synchronously
/// (writes are tiny and rare; keeps tests/UI crash-consistent).
final class PersonStore: ObservableObject {
    static let shared = PersonStore()

    @Published private(set) var people: [Person] = []
    /// The person currently on the scale — new weigh-ins auto-assign to them.
    @Published var activePersonId: UUID?
    /// The person whose records may flow to Apple Health (issue #14) — the
    /// profile that refers to the iOS device owner. `nil` = nobody.
    @Published private(set) var myPersonId: UUID?

    private let fileURL: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yantra", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("people.json")
        people = Self.load(from: fileURL)
        activePersonId = UserDefaults.standard.string(forKey: "activePersonId")
            .flatMap { UUID(uuidString: $0) }
        if activePersonId != nil && person(id: activePersonId!) == nil {
            activePersonId = nil
        }
        myPersonId = UserDefaults.standard.string(forKey: "myPersonId")
            .flatMap { UUID(uuidString: $0) }
        if myPersonId != nil && person(id: myPersonId!) == nil {
            myPersonId = nil
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

    /// Adds a person with their required profile, claiming `preferredSlot` or —
    /// when it is taken/out of range — the lowest free slot 1...5. Returns nil
    /// when all 5 slots are in use (scale limit: one user per slot).
    @discardableResult
    func add(name: String, profile: (sexMale: Bool, age: Int, heightCm: Double),
             preferredSlot: Int? = nil) -> Person? {
        let used = slotsInUse
        let slot = preferredSlot.flatMap { !used.contains($0) && (1...5).contains($0) ? $0 : nil }
            ?? (1...5).first { !used.contains($0) }
        guard let slot else { return nil }
        let p = Person(name: name, slot: slot,
                       sexMale: profile.sexMale, age: profile.age,
                       heightCm: profile.heightCm)
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

    /// Persists the person's profile (0x1001 user-info push + composition).
    func updateProfile(_ person: Person, sexMale: Bool, age: Int, heightCm: Double,
                       targetWeightKg: Double?? = nil) {
        mutate(person.id) {
            $0.sexMale = sexMale
            $0.age = age
            $0.heightCm = heightCm
            if let tw = targetWeightKg { $0.targetWeightKg = tw }
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
        if myPersonId == person.id {
            myPersonId = nil
            UserDefaults.standard.removeObject(forKey: "myPersonId")
        }
    }

    /// Marks `person` as the active weigh-in target (arms their scale slot).
    func setActive(_ person: Person) {
        activePersonId = person.id
        UserDefaults.standard.set(person.id.uuidString, forKey: "activePersonId")
    }

    /// Designates which profile is the iOS device owner (issue #14) — only
    /// their records are eligible for Apple Health export. Pass nil to clear.
    func setMyProfile(_ person: Person?) {
        myPersonId = person?.id
        if let p = person {
            UserDefaults.standard.set(p.id.uuidString, forKey: "myPersonId")
        } else {
            UserDefaults.standard.removeObject(forKey: "myPersonId")
        }
    }

    var myPerson: Person? {
        person(id: myPersonId)
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

/// A captured calibration sample with a stable identity for listing/deleting.
struct StoredCompositionSample: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var sample: CompositionSample

    static func == (lhs: StoredCompositionSample, rhs: StoredCompositionSample) -> Bool {
        lhs.id == rhs.id
    }
}

/// Store for body-composition calibration (SRD-006 FR-6): paired samples of
/// our raw weigh-in inputs + the values the official app displayed, plus the
/// fitted `BodyCalibration` derived from them.
final class CalibrationStore: ObservableObject {
    static let shared = CalibrationStore()

    @Published private(set) var samples: [StoredCompositionSample] = []
    @Published private(set) var calibration: BodyCalibration?
    /// Human-readable result of the last refit (shown in the UI).
    @Published private(set) var lastReport: String?

    private let dir: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yantra", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.dir = base
        samples = Self.loadSamples(url: base.appendingPathComponent("calibration-samples.json"))
        calibration = Self.loadCalibration(url: base.appendingPathComponent("calibration-fit.json"))
    }

    func add(_ sample: CompositionSample) {
        samples.append(StoredCompositionSample(sample: sample))
        persistSamples()
    }

    func remove(_ stored: StoredCompositionSample) {
        samples.removeAll { $0.id == stored.id }
        persistSamples()
    }

    /// Refits the calibration from captured samples. Returns a summary string
    /// (or why no fit was possible); stores the calibration on success.
    @discardableResult
    func refit() -> String {
        let fitted = BodyCalibration.fit(samples: samples.map(\.sample))
        guard let (cal, report) = fitted else {
            lastReport = "Not enough data — weigh in ≥ 4 times and enter the " +
                "official app's fat % for each (same person + profile)."
            calibration = nil
            persistCalibration()
            return lastReport!
        }
        calibration = cal
        lastReport = "Fitted: " + report.summary
        persistCalibration()
        return lastReport!
    }

    func resetFit() {
        calibration = nil
        lastReport = nil
        persistCalibration()
    }

    // MARK: Persistence

    private func persistSamples() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(samples) {
            try? data.write(to: dir.appendingPathComponent("calibration-samples.json"), options: .atomic)
        }
    }

    private func persistCalibration() {
        let url = dir.appendingPathComponent("calibration-fit.json")
        guard let calibration else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let data = try? JSONEncoder().encode(calibration) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func loadSamples(url: URL) -> [StoredCompositionSample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([StoredCompositionSample].self, from: data)) ?? []
    }

    private static func loadCalibration(url: URL) -> BodyCalibration? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BodyCalibration.self, from: data)
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
        /// `A641` feature bitmap read at bind/session (SRD-006 FR-2) — the
        /// firmware-metadata backup trail (SRD-007 FR-6).
        var featureBitmap: [UInt8]?
    }

    static let shared = BindStore()

    private let url = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Yantra/bind.json", isDirectory: false)

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

    /// Feature bitmap accessor (SRD-006 FR-2) — merges into the stored record.
    var featureBitmap: [UInt8]? {
        get { record?.featureBitmap }
        set {
            guard var rec = record, let newValue else { return }
            rec.featureBitmap = newValue
            record = rec
        }
    }
}

/// Scale configuration choices (SRD-005 FR-4): display unit + body-fat
/// formula set, pushed to the scale at session start. UserDefaults-backed.
final class ScaleConfigStore: ObservableObject {
    static let shared = ScaleConfigStore()

    @Published var unit: UnitType {
        didSet { defaults.set(unit.rawValue, forKey: "scaleUnit") }
    }
    /// nil = don't push a formula (scale default applies).
    @Published var formula: FormulaType? {
        didSet {
            defaults.set(formula.map { Int($0.rawValue) }, forKey: "scaleFormula")
        }
    }

    private let defaults = UserDefaults.standard

    init() {
        unit = UnitType(rawValue: UInt8(defaults.integer(forKey: "scaleUnit"))) ?? .kg
        formula = defaults.object(forKey: "scaleFormula")
            .flatMap { $0 as? Int }
            .flatMap { FormulaType(rawValue: UInt8($0)) }
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
