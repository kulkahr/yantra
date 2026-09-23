import Foundation

/// Scale configuration echo decoding + verification (SRD-005 FR-3) — ports of
/// `DataParseUtils.parseWeightUserInfoForA6` / `parseWeightTargetForA6` /
/// `parseWeightUnitTypeForA6`. The scale echoes pushed settings as
/// `0x2001` (user info) / `0x2003` (target) / `0x2004` (unit) and confirms
/// pushes with `0x1000` setting callbacks.
public enum ConfigEcho {

    public enum Mismatch: Equatable, CustomStringConvertible {
        case slot(expected: Int, got: Int)
        case sex(expectedMale: Bool, gotFemale: Bool)
        case age(expected: Int, got: Int)
        case heightCm(expected: Double, got: Double)
        case unit(expected: UnitType, got: UnitType)
        case targetKg(expected: Double?, got: Double?)
        case malformed(String)

        public var description: String {
            switch self {
            case .slot(let e, let g): return "slot \(g) ≠ \(e)"
            case .sex(let e, let g): return "sex \(g ? "f" : "m") ≠ \(e ? "f" : "m")"
            case .age(let e, let g): return "age \(g) ≠ \(e)"
            case .heightCm(let e, let g): return String(format: "height %.0f ≠ %.0f", g, e)
            case .unit(let e, let g): return "unit \(g) ≠ \(e)"
            case .targetKg(let e, let g): return "target \(g.map { String(format: "%.1f", $0) } ?? "nil") ≠ \(e.map { String(format: "%.1f", $0) } ?? "nil")"
            case .malformed(let why): return "malformed echo: \(why)"
            }
        }
    }

    // MARK: 0x2001 user-info echo
    // Layout (parseWeightUserInfoForA6): [cmd 2B][slot][sex 0m/1f][age][h×100 2B][athlete][activity][w×100 2B]

    public struct UserInfoEcho: Equatable {
        public var slot: Int
        public var sexMale: Bool
        public var age: Int
        public var heightCm: Double
        public var athlete: Bool
        public var activityLevel: Int
        public var weightKg: Double?
    }

    public static func parseUserInfo(_ payload: [UInt8]) -> UserInfoEcho? {
        guard payload.count >= 11 else { return nil }
        // Height is pushed as meters×100 (= cm); echo decodes identically.
        let heightCm = Double(A6Bytes.toShort(payload, at: 5))
        let w = A6Bytes.toShort(payload, at: 9)
        return UserInfoEcho(
            slot: Int(payload[2]),
            sexMale: payload[3] == 0,
            age: Int(payload[4]),
            heightCm: heightCm,
            athlete: payload[7] & 1 == 1,
            activityLevel: Int(payload[8]),
            weightKg: w == 0xFFFF ? nil : Double(w) / 100.0)
    }

    /// Verifies a user-info echo against the pushed profile (heights in meters).
    public static func verify(_ echo: UserInfoEcho, slot: Int, sexMale: Bool,
                              age: Int, heightMeters: Double) -> [Mismatch] {
        var out: [Mismatch] = []
        if echo.slot != slot { out.append(.slot(expected: slot, got: echo.slot)) }
        if echo.sexMale != sexMale { out.append(.sex(expectedMale: sexMale, gotFemale: !sexMale)) }
        if echo.age != age { out.append(.age(expected: age, got: echo.age)) }
        let wantCm = heightMeters * 100
        if abs(echo.heightCm - wantCm) > 1.0 { out.append(.heightCm(expected: wantCm, got: echo.heightCm)) }
        return out
    }

    // MARK: 0x2004 unit echo

    public static func parseUnit(_ payload: [UInt8]) -> UnitType? {
        guard payload.count >= 3 else { return nil }
        return UnitType(rawValue: payload[2])
    }

    // MARK: 0x2003 target echo
    // Layout (parseWeightTargetForA6): [cmd 2B][slot][enable][target×100 4B]

    public struct TargetEcho: Equatable {
        public var slot: Int
        public var enabled: Bool
        public var targetKg: Double?
    }

    public static func parseTarget(_ payload: [UInt8]) -> TargetEcho? {
        guard payload.count >= 8 else { return nil }
        let enabled = payload[3] == 1
        let raw = A6Bytes.toInt(payload, at: 4)
        return TargetEcho(slot: Int(payload[2]), enabled: enabled,
                          targetKg: enabled ? Double(raw) / 100.0 : nil)
    }

    public static func verify(_ echo: TargetEcho, slot: Int, targetKg: Double?) -> [Mismatch] {
        var out: [Mismatch] = []
        if echo.slot != slot { out.append(.slot(expected: slot, got: echo.slot)) }
        if echo.enabled != (targetKg != nil) {
            out.append(.targetKg(expected: targetKg, got: echo.targetKg))
        } else if let want = targetKg, let got = echo.targetKg, abs(want - got) > 0.05 {
            out.append(.targetKg(expected: want, got: got))
        }
        return out
    }

    // MARK: 0x1000 setting callback
    // The scale confirms each accepted push with a callback; byte layout per
    // decompiled handlers is [cmd 2B][type(1B)=config family][status(1B)].

    public struct SettingCallback: Equatable {
        public var configType: UInt8
        public var accepted: Bool
    }

    public static func parseSettingCallback(_ payload: [UInt8]) -> SettingCallback? {
        guard payload.count >= 4 else { return nil }
        return SettingCallback(configType: payload[2], accepted: payload[3] == 1)
    }
}

/// Battery voltage → percent mapping (SRD-006 §2). Raw `A640` byte:
/// `V = raw/100 + 1.6`. Percent uses the S11 LiSOCl2-style discharge curve
/// approximation (official aborts DFU ≤ 10 %; low-battery < 2.8 V ≈ < 20 %).
public enum Battery {
    public static func volts(rawByte: Int) -> Double {
        Double(rawByte & 0xFF) / 100.0 + 1.6
    }

    /// Piecewise-linear map over the usable 2.5–3.6 V window (clamped 0–100).
    public static func percent(volts: Double) -> Int {
        let points: [(v: Double, pct: Double)] = [
            (2.5, 0), (2.6, 5), (2.7, 10), (2.8, 20), (2.9, 35),
            (3.0, 55), (3.1, 75), (3.3, 90), (3.6, 100),
        ]
        guard volts > points[0].v else { return 0 }        // ≤ 2.5 V → empty
        guard volts < points[points.count - 1].v else { return 100 }   // ≥ 3.6 V → full
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            if volts >= a.v && volts <= b.v {
                let t = (volts - a.v) / (b.v - a.v)
                return Int((a.pct + t * (b.pct - a.pct)).rounded())
            }
        }
        return 100
    }

    public static func percent(rawByte: Int) -> Int {
        percent(volts: volts(rawByte: rawByte))
    }

    public static func isLow(rawByte: Int) -> Bool {
        volts(rawByte: rawByte) < 2.8
    }
}
