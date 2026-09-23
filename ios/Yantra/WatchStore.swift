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
    /// Average periodic SpO2 for the day (nil when no valid samples).
    var spo2Average: Int?
    /// Resting/auto HR samples pulled for the day (hour → bpm), for the timeline.
    var hrByHour: [Int: Int]
    var updatedAt: Date

    var sleepTotalMinutes: Double { sleepLightMinutes + sleepDeepMinutes + sleepRemMinutes }
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
            rec.sleepAwakeMinutes += sleep.awakeMinutes
            rec.sleepLightMinutes += sleep.lightMinutes
            rec.sleepDeepMinutes += sleep.deepMinutes
            rec.sleepRemMinutes += sleep.remMinutes
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
        persist()
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
