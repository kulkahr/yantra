import Foundation

/// Parser for `0x4802 DEVICE_A6_WEIGHT_DATA` records — port of
/// `DataParseUtils.parseWeightDataForA6` (payload INCLUDING the 2-byte command header).
public struct A6WeightRecord: Equatable {
    public let remainCount: Int
    public let unitRaw: Int                 // flags bits 0–1: 0 kg, 1 lb, 2 st, 3 jin
    public let weightKg: Double             // raw ×0.01 (kg when unit == 0)
    public var userId: Int?                 // flag bit 2
    public var utc: Int?                    // flag bit 3
    public var timeZone: Int?               // flag bit 4
    public var dateTime: [Int]?             // flag bit 5: [y, mo, d, h, mi, s]
    public var bmiRaw: Int?                 // flag bit 6
    public var fatRatioRaw: Int?            // flag bit 7
    public var basalMetabolismRaw: Int?     // flag bit 8
    public var muscleRatioRaw: Int?         // flag bit 9
    public var muscleRaw: Int?              // flag bit 10
    public var fatFreeRaw: Int?             // flag bit 11
    public var softLeanRaw: Int?            // flag bit 12
    public var waterRatioRaw: Int?          // flag bit 13
    public var impedanceOhm: Int?           // flag bit 14
    /// True when this record came from the scale's stored-memory drain rather
    /// than a live weigh-in: `remainCount > 0` means "more stored records
    /// follow", i.e. the scale is emptying memory recorded while disconnected
    /// (possibly by a different person) — issue #9. Set by
    /// `SessionStateMachine` on arrival, not parsed from the wire.
    public var fromMemoryDrain: Bool = false
}

public enum A6WeightRecordParser {

    /// - Parameter payload: full packet payload (command header included), CRC already stripped.
    public static func parse(_ payload: [UInt8]) -> A6WeightRecord? {
        // decompiled layout starts at offset 2 (skips nothing else — command header IS bytes 0–1)
        guard payload.count >= 10 else { return nil }
        let remain = A6Bytes.toShort(payload, at: 2)

        let flags = A6Bytes.toInt(payload, at: 4)
        let weight = Double(A6Bytes.toShort(payload, at: 8)) * 0.01

        var r = A6WeightRecord(remainCount: remain, unitRaw: flags & 3, weightKg: weight)
        var i = 10

        func take(_ n: Int) -> [UInt8] {
            defer { i += n }
            guard i + n <= payload.count else { return Array(repeating: 0, count: n) }
            return Array(payload[i..<(i + n)])
        }

        if (flags >> 2) & 1 == 1 {
            r.userId = Int(take(1)[0]) & 0xFF
        }
        if (flags >> 3) & 1 == 1 {
            let b = take(4)
            r.utc = A6Bytes.toInt(b, at: 0)
        }
        if (flags >> 4) & 1 == 1 {
            r.timeZone = Int(take(1)[0]) & 0xFF
        }
        if (flags >> 5) & 1 == 1 {
            let b = take(7)
            r.dateTime = [A6Bytes.toShort(b, at: 0) & 0xFFFF,
                          Int(b[2]), Int(b[3]), Int(b[4]), Int(b[5]), Int(b[6])]
        }
        if (flags >> 6) & 1 == 1 { r.bmiRaw = A6Bytes.toShort(take(2), at: 0) }
        if (flags >> 7) & 1 == 1 { r.fatRatioRaw = A6Bytes.toShort(take(2), at: 0) }
        if (flags >> 8) & 1 == 1 { r.basalMetabolismRaw = A6Bytes.toShort(take(2), at: 0) }
        if (flags >> 9) & 1 == 1 { r.muscleRatioRaw = A6Bytes.toShort(take(2), at: 0) }
        if (flags >> 10) & 1 == 1 { r.muscleRaw = A6Bytes.toShort(take(2), at: 0) }
        if (flags >> 11) & 1 == 1 { r.fatFreeRaw = A6Bytes.toShort(take(2), at: 0) }
        if (flags >> 12) & 1 == 1 { r.softLeanRaw = A6Bytes.toShort(take(2), at: 0) }
        if (flags >> 13) & 1 == 1 { r.waterRatioRaw = A6Bytes.toShort(take(2), at: 0) }
        if (flags >> 14) & 1 == 1 { r.impedanceOhm = A6Bytes.toShort(take(2), at: 0) }
        return r
    }
}
