import Foundation
import ScaleKit

/// One persisted watch health day (SRD-010 FR-2: local-only storage).
/// Keyed by calendar day; holds the aggregated metrics pulled from the watch.
struct WatchDayRecord: Codable, Equatable, Identifiable {
    /// `yyyy-MM-dd` (watch-local day the data belongs to).
    var id: String { dayKey }
    var dayKey: String
    var dayStart: Date
    /// Total steps for the day (latest live-steps snapshot while connected).
    var steps: Int
    var calories: Double
    var distanceMeters: Double
    /// Minutes per sleep stage aggregated across the day's hours.
    var sleepAwakeMinutes: Double
    var sleepLightMinutes: Double
    var sleepDeepMinutes: Double
    var sleepRemMinutes: Double
    /// QF3: per-hour sleep slots (`"sleep:<hour>"` → stage minutes) so repeated
    /// pulls of a day REPLACE instead of accumulate. Optional + decode-defaulted
    /// for records written before this field existed. (Tuples aren't Codable,
    /// so stages ride a small Codable struct.)
    var sleepSlots: [String: SleepStageMinutes]?
    /// Average periodic SpO2 for the day (nil when no valid samples).
    var spo2Average: Int?
    /// Resting/auto HR samples pulled for the day (hour → bpm), for the timeline.
    var hrByHour: [Int: Int]
    var updatedAt: Date

    var sleepTotalMinutes: Double { sleepLightMinutes + sleepDeepMinutes + sleepRemMinutes }

    /// QF3: Codable per-hour stage-minute bundle (tuples aren't Codable).
    struct SleepStageMinutes: Codable, Equatable {
        var awake: Double
        var light: Double
        var deep: Double
        var rem: Double
    }

    private enum CodingKeys: String, CodingKey {
        case dayKey, dayStart, steps, calories, distanceMeters
        case sleepAwakeMinutes, sleepLightMinutes, sleepDeepMinutes, sleepRemMinutes
        case sleepSlots, spo2Average, hrByHour, updatedAt
    }

    /// Explicit memberwise init — the custom `init(from:)` below suppresses
    /// the synthesized one, and `upsert` constructs full records.
    init(dayKey: String, dayStart: Date, steps: Int, calories: Double,
         distanceMeters: Double, sleepAwakeMinutes: Double, sleepLightMinutes: Double,
         sleepDeepMinutes: Double, sleepRemMinutes: Double,
         sleepSlots: [String: SleepStageMinutes]? = nil, spo2Average: Int?,
         hrByHour: [Int: Int], updatedAt: Date) {
        self.dayKey = dayKey
        self.dayStart = dayStart
        self.steps = steps
        self.calories = calories
        self.distanceMeters = distanceMeters
        self.sleepAwakeMinutes = sleepAwakeMinutes
        self.sleepLightMinutes = sleepLightMinutes
        self.sleepDeepMinutes = sleepDeepMinutes
        self.sleepRemMinutes = sleepRemMinutes
        self.sleepSlots = sleepSlots
        self.spo2Average = spo2Average
        self.hrByHour = hrByHour
        self.updatedAt = updatedAt
    }

    /// QF3 back-compat: records written before `sleepSlots` existed decode with
    /// nil slots (totals from the old accumulate path stay as-is).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try c.decode(String.self, forKey: .dayKey)
        dayStart = try c.decode(Date.self, forKey: .dayStart)
        steps = try c.decode(Int.self, forKey: .steps)
        calories = try c.decode(Double.self, forKey: .calories)
        distanceMeters = try c.decode(Double.self, forKey: .distanceMeters)
        sleepAwakeMinutes = try c.decode(Double.self, forKey: .sleepAwakeMinutes)
        sleepLightMinutes = try c.decode(Double.self, forKey: .sleepLightMinutes)
        sleepDeepMinutes = try c.decode(Double.self, forKey: .sleepDeepMinutes)
        sleepRemMinutes = try c.decode(Double.self, forKey: .sleepRemMinutes)
        sleepSlots = try c.decodeIfPresent([String: SleepStageMinutes].self,
                                           forKey: .sleepSlots)
        spo2Average = try c.decodeIfPresent(Int.self, forKey: .spo2Average)
        hrByHour = try c.decode([Int: Int].self, forKey: .hrByHour)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }
}

/// Persistent watch inventory (SRD-010 FR-2) —
/// `Application Support/Yantra/watchdata.json`. Local-only by design: nothing
/// leaves the device unless the user later opts into export (issue #14 model).
@MainActor
final class WatchStore: ObservableObject {
    static let shared = WatchStore()

    @Published private(set) var days: [WatchDayRecord] = []

    private let url: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yantra", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("watchdata.json")
        if let data = try? Data(contentsOf: url) {
            // Issue #39: persist() writes .iso8601 dates — decoder must match.
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            days = (try? decoder.decode([WatchDayRecord].self, from: data)) ?? []
            // Fix #23 (audit #23): canonicalize order + apply the retention
            // cap at load so a pre-cap file shrinks on first launch.
            days.sort { $0.dayKey > $1.dayKey }
            pruneRetention()
        }
    }

    func day(_ key: String) -> WatchDayRecord? {
        days.first { $0.dayKey == key }
    }

    /// Merges `patch` into the stored day (or inserts it), preserving fields
    /// the patch does not carry.
    func upsert(day key: String, dayStart: Date? = nil,
                steps: Int? = nil, calories: Double? = nil, distanceMeters: Double? = nil,
                sleep: KahaProtocol.SleepHour? = nil, spo2: [KahaProtocol.SpO2Sample]? = nil,
                hrByHour: [Int: Int]? = nil) {
        var rec = day(key) ?? WatchDayRecord(
            dayKey: key, dayStart: dayStart ?? Calendar.current.startOfDay(for: Date()),
            steps: 0, calories: 0, distanceMeters: 0,
            sleepAwakeMinutes: 0, sleepLightMinutes: 0, sleepDeepMinutes: 0, sleepRemMinutes: 0,
            spo2Average: nil, hrByHour: [:], updatedAt: Date())
        if let dayStart { rec.dayStart = dayStart }
        if let steps { rec.steps = steps }
        if let calories { rec.calories = calories }
        if let distanceMeters { rec.distanceMeters = distanceMeters }
        if let sleep {
            // QF3 (audit #23): REPLACE the stage minutes for this hour instead
            // of accumulating — re-pulling the same day previously inflated
            // sleep totals every time (+= per hour). Per-hour slots keyed by
            // `SleepHour.hour`; a pull of the same day overwrites, a pull of a
            // different hour range merges the untouched hours.
            let slotKey = "sleep:\(sleep.hour)"
            var slots = rec.sleepSlots ?? [:]
            slots[slotKey] = SleepStageMinutes(awake: sleep.awakeMinutes,
                                               light: sleep.lightMinutes,
                                               deep: sleep.deepMinutes,
                                               rem: sleep.remMinutes)
            rec.sleepSlots = slots
            let totals = slots.values.reduce(SleepStageMinutes(awake: 0, light: 0, deep: 0, rem: 0)) {
                SleepStageMinutes(awake: $0.awake + $1.awake,
                                  light: $0.light + $1.light,
                                  deep: $0.deep + $1.deep,
                                  rem: $0.rem + $1.rem)
            }
            rec.sleepAwakeMinutes = totals.awake
            rec.sleepLightMinutes = totals.light
            rec.sleepDeepMinutes = totals.deep
            rec.sleepRemMinutes = totals.rem
        }
        if let spo2, !spo2.isEmpty {
            let avg = spo2.map { $0.percent }.reduce(0, +) / spo2.count
            rec.spo2Average = avg
        }
        if let hrByHour { rec.hrByHour.merge(hrByHour) { _, new in new } }
        rec.updatedAt = Date()

        if let i = days.firstIndex(where: { $0.dayKey == key }) {
            days[i] = rec
        } else {
            days.append(rec)
        }
        days.sort { $0.dayKey > $1.dayKey }
        pruneRetention()
        persist()
    }

    /// Fix #23 (audit #23): retention policy — keep the newest 365 days and
    /// drop older records on every write. Rationale: the watch itself retains
    /// only 7 days (`maxDaysOf*DataOnBand`), so anything older than a year has
    /// no live source to refresh it; a one-year local window matches typical
    /// health-data horizons while keeping `watchdata.json` bounded. (Days is
    /// sorted newest-first, so the tail is the oldest.)
    private static let retentionDays = 365

    private func pruneRetention() {
        guard days.count > Self.retentionDays else { return }
        days.removeLast(days.count - Self.retentionDays)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(days) {
            try? data.write(to: url, options: .atomic)
        }
    }

    nonisolated static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
