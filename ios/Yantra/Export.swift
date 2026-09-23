import Foundation
import HealthKit
import ScaleKit

/// CSV export of stored measurements (SRD-004 FR-6 — explicit user action only).
enum CSVExporter {
    static func export(records: [MeasurementRecord], people: [Person] = []) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = .current
        func csv(_ s: String) -> String {
            s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var rows = ["utc,weight_kg,impedance_ohm,device_id,slot,person"]
        for r in records.sorted(by: { $0.utc < $1.utc }) {
            let person = people.first { $0.id == r.personId }?.name ?? ""
            let cols = [f.string(from: r.utc),
                        String(format: "%.2f", r.weightKg),
                        r.impedanceOhm.map(String.init) ?? "",
                        r.deviceId,
                        String(r.slot),
                        csv(person)]
            rows.append(cols.joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }
}

/// Opt-in Apple Health export (SRD-004 FR-6). Requires the HealthKit entitlement;
/// silently reports unavailable when missing (e.g. simulator).
///
/// Issue #11: every sample is tagged with its MeasurementRecord id and a query
/// filters out ids already in Health, so repeated taps never create duplicates.
enum HealthKitWriter {
    static let recordIdKey = "fireflyRecordId"

    static func writeWeight(records: [MeasurementRecord]) -> String {
        guard HKHealthStore.isHealthDataAvailable() else {
            return "HealthKit unavailable on this device"
        }
        guard !records.isEmpty else { return "No records to export" }
        let store = HKHealthStore()
        let type = HKQuantityType(.bodyMass)
        store.requestAuthorization(toShare: [type], read: [type]) { ok, error in
            guard ok, error == nil else { return }
            // One query for all record ids already saved in Health.
            let ids = records.map { $0.id.uuidString }
            let existing = HKQuery.predicateForObjects(
                withMetadataKey: recordIdKey, allowedValues: ids)
            let query = HKSampleQuery(sampleType: type, predicate: existing,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil)
            { _, samples, _ in
                let savedIds = Set((samples as? [HKQuantitySample] ?? [])
                    .compactMap { $0.metadata?[recordIdKey] as? String })
                let fresh = records.filter { !savedIds.contains($0.id.uuidString) }
                DispatchQueue.main.async {
                    for r in fresh {
                        let q = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: r.weightKg)
                        let sample = HKQuantitySample(type: type, quantity: q,
                                                      start: r.utc, end: r.utc,
                                                      metadata: [recordIdKey: r.id.uuidString])
                        store.save(sample) { _, _ in }
                    }
                }
            }
            store.execute(query)
        }
        return "Writing \(records.count) sample(s) to Health (skipping already saved)…"
    }

    /// Issue #29: export persisted watch metrics (WatchStore) into HealthKit.
    /// Steps per day, HR samples, sleep-analysis stages and SpO2, each with a
    /// dedupe metadata key `watchDay:<dayKey>` so re-exports never duplicate.
    static func writeWatchDays(_ days: [WatchDayRecord]) -> String {
        guard HKHealthStore.isHealthDataAvailable() else {
            return "HealthKit unavailable on this device"
        }
        guard !days.isEmpty else { return "No watch data to export" }
        let types = Set([
            HKQuantityType(.stepCount), HKQuantityType(.heartRate),
            HKCategoryType(.sleepAnalysis), HKQuantityType(.oxygenSaturation),
        ])
        let store = HKHealthStore()
        store.requestAuthorization(toShare: types, read: types) { ok, _ in
            guard ok else { return }
            DispatchQueue.main.async {
                for day in days { exportDay(day, store: store) }
            }
        }
        return "Writing \(days.count) day(s) of watch data to Health…"
    }

    private static func exportDay(_ day: WatchDayRecord, store: HKHealthStore) {
        let cal = Calendar.current
        let dayEnd = cal.date(byAdding: .day, value: 1, to: day.dayStart) ?? day.dayStart
        let meta = [recordIdKey: "watch\(day.dayKey)"]

        // Steps as one cumulative sample across the day.
        if day.steps > 0 {
            let type = HKQuantityType(.stepCount)
            store.save(HKQuantitySample(type: type,
                                        quantity: HKQuantity(unit: .count(), doubleValue: Double(day.steps)),
                                        start: day.dayStart, end: dayEnd, metadata: meta), withCompletion: { _, _ in })
        }
        // Hourly heart-rate samples.
        let hrType = HKQuantityType(.heartRate)
        for (hour, bpm) in day.hrByHour where bpm > 0 {
            guard let start = cal.date(bySettingHour: hour, minute: 0, second: 0,
                                       of: day.dayStart) else { continue }
            let end = start.addingTimeInterval(3600)
            store.save(HKQuantitySample(type: hrType,
                                        quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: Double(bpm)),
                                        start: start, end: end, metadata: meta), withCompletion: { _, _ in })
        }
        // Sleep stages as category samples (light->asleepCore, deep->asleepDeep, REM->asleepREM).
        let sleepType = HKCategoryType(.sleepAnalysis)
        var cursor = day.dayStart
        for (mins, stage) in [(day.sleepLightMinutes, HKCategoryValueSleepAnalysis.asleepCore),
                             (day.sleepDeepMinutes, HKCategoryValueSleepAnalysis.asleepDeep),
                             (day.sleepRemMinutes, HKCategoryValueSleepAnalysis.asleepREM)] where mins > 0 {
            let end = cursor.addingTimeInterval(mins * 60)
            let sample = HKCategorySample(type: sleepType, value: stage.rawValue,
                                          start: cursor, end: end, metadata: meta)
            store.save(sample, withCompletion: { _, _ in })
            cursor = end
        }
        // Daily SpO2 average.
        if let spo2 = day.spo2Average, spo2 > 0 {
            let type = HKQuantityType(.oxygenSaturation)
            store.save(HKQuantitySample(type: type,
                                        quantity: HKQuantity(unit: .percent(), doubleValue: Double(spo2) / 100),
                                        start: day.dayStart, end: dayEnd, metadata: meta), withCompletion: { _, _ in })
        }
    }
}
