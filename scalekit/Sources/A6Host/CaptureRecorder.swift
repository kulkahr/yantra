import Foundation
import ScaleKit

/// Writes replay-format captures (schema v1, `analysis/captures/README.md`).
/// Device→app bytes are logged verbatim the moment they arrive — the capture
/// must not encode our protocol assumptions. Reference type: host and driver
/// share the same sink.
final class CaptureRecorder {
    let mac: String
    var firmwareVersion: String
    let kind: String            // "pair" | "session"
    var notes: String

    private var events: [[String: Any]] = []
    private let start = Date()

    init(mac: String, firmwareVersion: String, kind: String, notes: String) {
        self.mac = mac
        self.firmwareVersion = firmwareVersion
        self.kind = kind
        self.notes = notes
    }

    var eventCount: Int { events.count }

    /// Record one raw notify exactly as it arrived (A621/A625).
    func record(characteristic: UUID, data: Data) {
        events.append([
            "t": roundedNow(),
            "char": shortName(characteristic),
            "hex": data.map { String(format: "%02X", $0) }.joined(),
        ])
    }

    /// Record a read response (A641 feature, A640 voltage, 180a chars).
    /// Replay feeds these to the machine as `.readResponse` events.
    func recordRead(characteristic: UUID, data: Data) {
        events.append([
            "t": roundedNow(),
            "char": shortName(characteristic),
            "hex": data.map { String(format: "%02X", $0) }.joined(),
            "read": true,
        ])
    }

    /// Serialize to the v1 JSON capture format.
    func json() throws -> Data {
        var meta: [String: Any] = [
            "mac": mac,
            "firmwareVersion": firmwareVersion,
            "kind": kind,
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        if !notes.isEmpty { meta["notes"] = notes }
        let obj: [String: Any] = ["version": 1, "meta": meta, "events": events]
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    private func roundedNow() -> Double {
        Double(Int(Date().timeIntervalSince(start) * 1000)) / 1000
    }

    private func shortName(_ uuid: UUID) -> String {
        switch uuid {
        case GATT.notifyData: return "A621"
        case GATT.notifyAck: return "A625"
        case GATT.writeData: return "A624"
        case GATT.writeAck: return "A622"
        case GATTPlus.a6Broadcast: return "A620"
        case GATTPlus.otaData: return "1531"
        case GATT.featureInfo: return "A641"
        case GATT.voltage: return "A640"
        default: return uuid.uuidString
        }
    }
}
