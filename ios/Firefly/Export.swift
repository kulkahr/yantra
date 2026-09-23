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
            var cols = [f.string(from: r.utc),
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
enum HealthKitWriter {
    static func writeWeight(records: [MeasurementRecord]) -> String {
        guard HKHealthStore.isHealthDataAvailable() else {
            return "HealthKit unavailable on this device"
        }
        let store = HKHealthStore()
        let type = HKQuantityType(.bodyMass)
        store.requestAuthorization(toShare: [type], read: nil) { ok, error in
            guard ok, error == nil else { return }
            DispatchQueue.main.async {
                for r in records {
                    let q = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: r.weightKg)
                    let sample = HKQuantitySample(type: type, quantity: q, start: r.utc, end: r.utc)
                    store.save(sample) { _, _ in }
                }
            }
        }
        return "Writing \(records.count) sample(s) to Health…"
    }
}
