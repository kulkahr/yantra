import Foundation

/// Client-side body-composition computation (SRD-006) — the scale sends only raw
/// weight + impedance; all derived metrics are computed here, exactly like the
/// official app does (`WeightData_A3` bean + JS-bridge chart handlers).
///
/// v1 formula set (documented approximations, tuned vs official readings later
/// per FUTURE_PLAN Phase 3):
/// - BMI: weight / height²
/// - Fat % (impedance present): openScale-style BIA regression —
///   FFM = α·h_cm²/R + β·W + γ (male α=0.35 β=0.50 γ=3.0;
///   female α=0.30 β=0.45 γ=4.0), fat% = (W−FFM)/W.
///   Sanity envelope: 70.75 kg / 175 cm / R 585 Ω → male ≈ 20 % fat,
///   female ≈ 27 %; athlete (R 450) → ≈ 12 %. Tuned vs official readings later.
/// - Fat % (no impedance): Deurenberg — 1.20·BMI + 0.23·age − 10.8·sex − 5.4.
/// - Water %: lean tissue ≈ 73 % water → waterMass = 0.73·FFM.
/// - Muscle: skeletal muscle ≈ 0.50·FFM (male) / 0.45·FFM (female).
/// - Bone: mineral ≈ 0.055·FFM; soft-lean = FFM − bone.
/// - Basal metabolism: Mifflin-St Jeor.
/// - Visceral fat level: empirical placeholder (fat-mass scaled, age/sex bump),
///   explicitly marked for tuning.
public enum BodyComposer {

    public struct Profile: Equatable {
        public var sexMale: Bool
        public var age: Int
        public var heightMeters: Double

        public init(sexMale: Bool, age: Int, heightMeters: Double) {
            self.sexMale = sexMale
            self.age = age
            self.heightMeters = heightMeters
        }
    }

    public struct Composition: Equatable {
        public let bmi: Double
        public let fatPercent: Double
        public let waterPercent: Double
        public let muscleKg: Double
        public let fatFreeKg: Double
        public let softLeanKg: Double
        public let boneKg: Double
        public let basalMetabolismKcal: Int
        public let visceralFatLevel: Double
        /// `false` when fat% came from the BMI fallback (no impedance available).
        public let impedanceBased: Bool
    }

    /// Compose from raw inputs. `impedanceOhm == nil` → BMI-fallback fat%.
    public static func compose(weightKg: Double, impedanceOhm: Double?,
                               profile: Profile) -> Composition {
        let h = max(0.5, profile.heightMeters)
        let h2 = h * h
        let age = max(1, profile.age)

        let bmi = weightKg / h2

        var impedanceBased = true
        var fatFree: Double
        if let r = impedanceOhm, r > 0 {
            let hCm2 = pow(h * 100, 2)
            let (a, b, c): (Double, Double, Double) = profile.sexMale ? (0.35, 0.50, 3.0) : (0.30, 0.45, 4.0)
            fatFree = a * hCm2 / r + b * weightKg + c
        } else {
            impedanceBased = false
            let sexTerm = profile.sexMale ? 10.8 : 0.0
            let fat = 1.20 * bmi + 0.23 * Double(age) - sexTerm - 5.4
            fatFree = weightKg * (1 - clamp(fat, 2...60) / 100)
        }
        fatFree = clamp(fatFree, 0...weightKg)

        let fatMass = weightKg - fatFree
        let fatPercent = weightKg > 0 ? clamp(fatMass / weightKg * 100, 2...60) : 0
        let waterPercent = clamp(0.73 * fatFree / max(weightKg, 0.01) * 100, 20...75)
        let bone = 0.055 * fatFree
        let muscle = (profile.sexMale ? 0.50 : 0.45) * fatFree
        let softLean = fatFree - bone

        let bmr = profile.sexMale
            ? 10 * weightKg + 6.25 * (h * 100) - 5 * Double(age) + 5
            : 10 * weightKg + 6.25 * (h * 100) - 5 * Double(age) - 161

        // Visceral-fat placeholder: fat-mass scaled with age/sex bump (tune vs app).
        let vfl = fatMass * 0.1 + Double(age) / 100 + (profile.sexMale ? 0.5 : 0)

        return Composition(
            bmi: bmi,
            fatPercent: fatPercent,
            waterPercent: waterPercent,
            muscleKg: muscle,
            fatFreeKg: fatFree,
            softLeanKg: max(softLean, 0),
            boneKg: bone,
            basalMetabolismKcal: Int(bmr.rounded()),
            visceralFatLevel: (vfl * 10).rounded() / 10,
            impedanceBased: impedanceBased)
    }

    /// Convenience: compose from a parsed `0x4802` record (impedance only when the
    /// record carried it — flag bit 14).
    public static func compose(record: A6WeightRecord, profile: Profile) -> Composition {
        compose(weightKg: record.weightKg,
                impedanceOhm: record.impedanceOhm.map(Double.init),
                profile: profile)
    }

    private static func clamp(_ v: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }
}
