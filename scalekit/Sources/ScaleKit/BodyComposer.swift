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
        /// Fat mass in kg (issue #7).
        public let fatMassKg: Double
        public let waterPercent: Double
        public let muscleKg: Double
        /// Skeletal-muscle percentage of body weight (issue #7).
        public let musclePercent: Double
        public let fatFreeKg: Double
        public let softLeanKg: Double
        public let boneKg: Double
        /// Protein ≈ 16 % of fat-free mass (issue #7; typical body-protein share
        /// of FFM, tune vs official readings later).
        public let proteinKg: Double
        public let basalMetabolismKcal: Int
        public let visceralFatLevel: Double
        /// `false` when fat% came from the BMI fallback (no impedance available).
        public let impedanceBased: Bool
    }

    /// Compose from raw inputs. `impedanceOhm == nil` → BMI-fallback fat%.
    /// `calibration` applies corrections fitted against official-app readings
    /// (SRD-006 FR-6) — see `BodyCalibration`.
    public static func compose(weightKg: Double, impedanceOhm: Double?,
                               profile: Profile,
                               calibration: BodyCalibration = .standard) -> Composition {
        let h = max(0.5, profile.heightMeters)
        let h2 = h * h
        let age = max(1, profile.age)

        let bmi = weightKg / h2

        var impedanceBased = true
        var fatFree: Double
        var fatPercentRaw: Double?
        if let r = impedanceOhm, r > 0 {
            if let fit = calibration.fatFit {
                // Fitted impedance model (official-app parity path).
                fatPercentRaw = fit.evaluate(heightCm: h * 100, impedanceOhm: r,
                                             weightKg: weightKg, ageYears: Double(age))
                fatFree = weightKg * (1 - clamp(fatPercentRaw!, 2...60) / 100)
            } else {
                let hCm2 = pow(h * 100, 2)
                let (a, b, c): (Double, Double, Double) = profile.sexMale ? (0.35, 0.50, 3.0) : (0.30, 0.45, 4.0)
                fatFree = a * hCm2 / r + b * weightKg + c
            }
        } else {
            impedanceBased = false
            let sexTerm = profile.sexMale ? 10.8 : 0.0
            let fat = 1.20 * bmi + 0.23 * Double(age) - sexTerm - 5.4
                + calibration.fallbackFatOffset
            fatFree = weightKg * (1 - clamp(fat, 2...60) / 100)
        }
        fatFree = clamp(fatFree, 0...weightKg)

        // Base (uncorrected) metric values — affine corrections apply to these.
        var fatMass = weightKg - fatFree
        let fatPercent = fatPercentRaw.map {
            clamp($0, 2...60)
        } ?? (weightKg > 0 ? clamp(fatMass / weightKg * 100, 2...60) : 0)
        var waterPercent = clamp(0.73 * fatFree / max(weightKg, 0.01) * 100, 20...75)
        var bone = 0.055 * fatFree
        var muscle = (profile.sexMale ? 0.50 : 0.45) * fatFree
        var musclePercent = weightKg > 0 ? clamp(muscle / weightKg * 100, 0...60) : 0
        var softLean = fatFree - bone
        var protein = 0.16 * fatFree
        var bmr = profile.sexMale
            ? 10 * weightKg + 6.25 * (h * 100) - 5 * Double(age) + 5
            : 10 * weightKg + 6.25 * (h * 100) - 5 * Double(age) - 161
        var vfl = fatMass * 0.1 + Double(age) / 100 + (profile.sexMale ? 0.5 : 0)

        // Fitted affine corrections (official-app parity), each applied to the
        // BASE value — mirrors BodyCalibration.fit semantics.
        func corrected(_ metric: CalibrationMetric, _ v: Double) -> Double {
            calibration.corrections[metric.rawValue]?.apply(v) ?? v
        }
        fatMass = corrected(.fatMassKg, fatMass)
        waterPercent = corrected(.waterPercent, waterPercent)
        bone = corrected(.boneKg, bone)
        muscle = corrected(.muscleKg, muscle)
        musclePercent = corrected(.musclePercent, musclePercent)
        softLean = corrected(.softLeanKg, softLean)
        protein = corrected(.proteinKg, protein)
        bmr = corrected(.basalMetabolismKcal, bmr)
        vfl = corrected(.visceralFatLevel, vfl)

        return Composition(
            bmi: bmi,
            fatPercent: fatPercent,
            fatMassKg: max(fatMass, 0),
            waterPercent: clamp(waterPercent, 20...75),
            muscleKg: max(muscle, 0),
            musclePercent: clamp(musclePercent, 0...60),
            fatFreeKg: fatFree,
            softLeanKg: max(softLean, 0),
            boneKg: max(bone, 0),
            proteinKg: max(protein, 0),
            basalMetabolismKcal: Int(bmr.rounded()),
            visceralFatLevel: (max(vfl, 0) * 10).rounded() / 10,
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
