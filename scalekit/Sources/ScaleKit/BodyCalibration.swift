import Foundation

/// Per-metric calibration of `BodyComposer` against official-app readings
/// (SRD-006 FR-6: ±0.1 % body-fat, ±1 kcal BMR vs realme Link on the same
/// measurement + profile).
///
/// Why: the official app uploads only raw weight + impedance to Lifesense's
/// cloud (`weight_service/weight/syncToServer`, verified in the decompiled
/// APK) and displays the cloud-computed composition — the exact formulas are
/// not extractable. This type lets us *fit* them instead: capture paired
/// samples (our raw inputs + the values the official app shows), run a
/// least-squares refit, and apply the result.
///
/// Model (see `BodyComposer.compose` for how it is applied):
/// 1. Fat % (impedance path), fitted directly on raw features —
///    `fat% = f0 + f1·(h_cm²/R) + f2·W + f3·age` (features with zero variance
///    across samples are dropped, so a single user's constant age is fine).
///    `nil` = the standard openScale-style sex-split formula (v1 behavior).
/// 2. Fat % (no impedance): Deurenberg base + `fallbackFatOffset`.
/// 3. Every other metric: affine correction `v' = slope·v + intercept`
///    applied to the base-model value, keyed by `CalibrationMetric`.
public struct BodyCalibration: Equatable, Codable {
    /// Least-squares fit of the impedance fat% model.
    public struct FatFit: Equatable, Codable {
        public var intercept: Double
        public var h2OverR: Double
        public var weight: Double
        public var age: Double

        public init(intercept: Double, h2OverR: Double, weight: Double, age: Double) {
            self.intercept = intercept
            self.h2OverR = h2OverR
            self.weight = weight
            self.age = age
        }

        public func evaluate(heightCm: Double, impedanceOhm: Double,
                             weightKg: Double, ageYears: Double) -> Double {
            intercept + h2OverR * (heightCm * heightCm / impedanceOhm)
                + weight * weightKg + age * ageYears
        }
    }

    /// Affine correction `value' = slope·value + intercept`.
    public struct Affine: Equatable, Codable {
        public var slope: Double
        public var intercept: Double

        public init(slope: Double = 1, intercept: Double = 0) {
            self.slope = slope
            self.intercept = intercept
        }

        public var isIdentity: Bool { slope == 1 && intercept == 0 }

        public func apply(_ v: Double) -> Double { slope * v + intercept }
    }

    /// Offset added to the Deurenberg fat% estimate when no impedance is present.
    public var fallbackFatOffset: Double
    /// Fitted impedance fat% model; `nil` = standard formula set.
    public var fatFit: FatFit?
    /// Per-metric affine corrections applied on top of the base model.
    public var corrections: [String: Affine]

    public init(fallbackFatOffset: Double = 0, fatFit: FatFit? = nil,
                corrections: [String: Affine] = [:]) {
        self.fallbackFatOffset = fallbackFatOffset
        self.fatFit = fatFit
        self.corrections = corrections
    }

    /// The un-tuned v1 formula set.
    public static let standard = BodyCalibration()

    public var isStandard: Bool {
        self == .standard
    }
}

/// Metrics that can carry an affine correction (keys of
/// `BodyCalibration.corrections`; `bmi` is exact and never corrected).
public enum CalibrationMetric: String, CaseIterable, Codable {
    case fatPercent
    case fatMassKg
    case waterPercent
    case muscleKg
    case musclePercent
    case fatFreeKg
    case softLeanKg
    case boneKg
    case proteinKg
    case basalMetabolismKcal
    case visceralFatLevel
}

/// One paired observation: our raw inputs + the composition the official app
/// displayed for the same weigh-in. Persisted by the app between refits.
public struct CompositionSample: Equatable, Codable {
    public var utc: Date
    public var weightKg: Double
    public var impedanceOhm: Double?
    public var sexMale: Bool
    public var age: Int
    public var heightCm: Double

    // Official-app values (all optional — the fitter uses what is present).
    public var officialFatPercent: Double?
    public var officialFatMassKg: Double?
    public var officialWaterPercent: Double?
    public var officialMuscleKg: Double?
    public var officialMusclePercent: Double?
    public var officialFatFreeKg: Double?
    public var officialSoftLeanKg: Double?
    public var officialBoneKg: Double?
    public var officialProteinKg: Double?
    public var officialBMRKcal: Double?
    public var officialVisceralLevel: Double?

    public init(utc: Date = Date(), weightKg: Double, impedanceOhm: Double?,
                sexMale: Bool, age: Int, heightCm: Double) {
        self.utc = utc
        self.weightKg = weightKg
        self.impedanceOhm = impedanceOhm
        self.sexMale = sexMale
        self.age = age
        self.heightCm = heightCm
    }
}

// MARK: - Fitting

/// Quality report for a fit — shown in the app after "Refit".
public struct CalibrationFitReport: Equatable {
    public let sampleCount: Int
    /// Max |predicted − official| fat% across fitted samples (percentage points).
    public let maxFatResidual: Double?
    /// RMS residual per corrected metric, in the metric's own unit.
    public let rmsResiduals: [String: Double]
    public var summary: String {
        var parts: [String] = ["\(sampleCount) sample(s)"]
        if let f = maxFatResidual { parts.append(String(format: "fat Δ%.2f%%", f)) }
        for (k, v) in rmsResiduals.sorted(by: { $0.key < $1.key }) {
            parts.append(String(format: "%@ Δ%.2f", k, v))
        }
        return parts.joined(separator: ", ")
    }
}

extension BodyCalibration {
    /// Fit a calibration from paired samples. Returns `nil` when there is not
    /// enough usable data (needs ≥ 4 impedance samples with official fat% for
    /// the fat model; ≥ 2 samples per affine metric).
    public static func fit(samples: [CompositionSample]) -> (calibration: BodyCalibration, report: CalibrationFitReport)? {
        // --- 1. Fat % (impedance): fat% = c0 + c1·h²/R + c2·W + c3·age ---
        var fatFit: FatFit?
        var fatResiduals: [Double] = []
        let fatRows = samples.filter { $0.impedanceOhm.map { $0 > 0 } == true && $0.officialFatPercent != nil }
        if fatRows.count >= 4 {
            // Column order: intercept, h²/R, W, age — drop zero-variance columns
            // (e.g. a single user's constant age) so the system stays full-rank.
            let featureRows: [[Double]] = fatRows.map { s in
                [1, pow(s.heightCm, 2) / s.impedanceOhm!, s.weightKg, Double(s.age)]
            }
            // Intercept (col 0) is always kept; only feature columns are
            // dropped for zero variance.
            var keep: [Int] = [0]
            for col in 1..<4 {
                let vals = featureRows.map { $0[col] }
                if columnVariance(vals) > 1e-12 { keep.append(col) }
            }
            if !keep.isEmpty, let coef = LeastSquares.solve(
                design: featureRows.map { row in keep.map { row[$0] } },
                target: fatRows.map { $0.officialFatPercent! })
            {
                func c(_ name: Int) -> Double {
                    guard let idx = keep.firstIndex(of: name) else { return 0 }
                    return coef[idx]
                }
                fatFit = FatFit(intercept: c(0), h2OverR: c(1), weight: c(2), age: c(3))
                let candidate = BodyCalibration(fallbackFatOffset: 0, fatFit: fatFit, corrections: [:])
                fatResiduals = fatRows.map {
                    abs(BodyComposer.compose(weightKg: $0.weightKg, impedanceOhm: $0.impedanceOhm,
                                             profile: $0.profile, calibration: candidate).fatPercent
                        - $0.officialFatPercent!)
                }
            }
        }

        // --- 2. Fallback offset: mean(official − Deurenberg) over no-impedance samples ---
        let fallbackRows = samples.filter { ($0.impedanceOhm.map { $0 > 0 } ?? false) == false && $0.officialFatPercent != nil }
        var fallbackOffset = 0.0
        if !fallbackRows.isEmpty {
            let errs = fallbackRows.map { s -> Double in
                let bmi = s.weightKg / pow(s.heightCm / 100, 2)
                let sex = s.sexMale ? 10.8 : 0.0
                let base = 1.20 * bmi + 0.23 * Double(s.age) - sex - 5.4
                return s.officialFatPercent! - base
            }
            fallbackOffset = errs.reduce(0, +) / Double(errs.count)
        }

        // --- 3. Per-metric affine corrections (base = fat-fitted, uncorrected) ---
        var corrections: [String: Affine] = [:]
        var rms: [String: Double] = [:]
        let candidate = BodyCalibration(fallbackFatOffset: fallbackOffset, fatFit: fatFit, corrections: [:])
        for metric in CalibrationMetric.allCases {
            // Fat % is fitted directly on raw features (the FatFit model);
            // a second affine layer on top would be unidentifiable.
            guard metric != .fatPercent else { continue }
            let pairs: [(x: Double, y: Double)] = samples.compactMap { s in
                let official = Self.official(s, metric: metric)
                guard let official else { return nil }
                let base = Self.baseValue(of: BodyComposer.compose(
                    weightKg: s.weightKg, impedanceOhm: s.impedanceOhm,
                    profile: s.profile, calibration: candidate), metric: metric)
                return (base, official)
            }
            guard pairs.count >= 2, let aff = LeastSquares.affine(pairs: pairs) else { continue }
            if !aff.isIdentity {
                corrections[metric.rawValue] = aff
                let residuals = pairs.map { pow($0.y - aff.apply($0.x), 2) }
                rms[metric.rawValue] = (residuals.reduce(0, +) / Double(residuals.count)).squareRoot()
            }
        }

        guard fatFit != nil || !corrections.isEmpty || fallbackOffset != 0 else { return nil }
        let calibration = BodyCalibration(fallbackFatOffset: fallbackOffset,
                                          fatFit: fatFit, corrections: corrections)
        let report = CalibrationFitReport(
            sampleCount: samples.count,
            maxFatResidual: fatResiduals.max(),
            rmsResiduals: rms)
        return (calibration, report)
    }

    static func official(_ s: CompositionSample, metric: CalibrationMetric) -> Double? {
        switch metric {
        case .fatPercent: return s.officialFatPercent
        case .fatMassKg: return s.officialFatMassKg
        case .waterPercent: return s.officialWaterPercent
        case .muscleKg: return s.officialMuscleKg
        case .musclePercent: return s.officialMusclePercent
        case .fatFreeKg: return s.officialFatFreeKg
        case .softLeanKg: return s.officialSoftLeanKg
        case .boneKg: return s.officialBoneKg
        case .proteinKg: return s.officialProteinKg
        case .basalMetabolismKcal: return s.officialBMRKcal
        case .visceralFatLevel: return s.officialVisceralLevel
        }
    }

    static func baseValue(of c: BodyComposer.Composition, metric: CalibrationMetric) -> Double {
        switch metric {
        case .fatPercent: return c.fatPercent
        case .fatMassKg: return c.fatMassKg
        case .waterPercent: return c.waterPercent
        case .muscleKg: return c.muscleKg
        case .musclePercent: return c.musclePercent
        case .fatFreeKg: return c.fatFreeKg
        case .softLeanKg: return c.softLeanKg
        case .boneKg: return c.boneKg
        case .proteinKg: return c.proteinKg
        case .basalMetabolismKcal: return Double(c.basalMetabolismKcal)
        case .visceralFatLevel: return c.visceralFatLevel
        }
    }

    private static func columnVariance(_ v: [Double]) -> Double {
        guard v.count > 1 else { return 0 }
        let mean = v.reduce(0, +) / Double(v.count)
        return v.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(v.count)
    }
}

// MARK: - Least squares

enum LeastSquares {
    /// Solves the full-rank linear system `A·c = y` (normal equations) via
    /// Gaussian elimination with partial pivoting. `nil` when singular.
    static func solve(design: [[Double]], target: [Double]) -> [Double]? {
        let n = design.first?.count ?? 0
        guard n > 0, design.count >= n, target.count == design.count else { return nil }
        var a = design
        var y = target
        for col in 0..<n {
            // Partial pivot.
            var pivot = col
            for row in (col + 1)..<design.count where abs(a[row][col]) > abs(a[pivot][col]) {
                pivot = row
            }
            guard abs(a[pivot][col]) > 1e-10 else { return nil }
            a.swapAt(col, pivot)
            y.swapAt(col, pivot)
            for row in (col + 1)..<design.count {
                let factor = a[row][col] / a[col][col]
                if factor == 0 { continue }
                for k in col..<n { a[row][k] -= factor * a[col][k] }
                y[row] -= factor * y[col]
            }
        }
        var c = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = y[row]
            for k in (row + 1)..<n { sum -= a[row][k] * c[k] }
            c[row] = sum / a[row][row]
        }
        return c
    }

    /// Closed-form least squares for `y ≈ slope·x + intercept`.
    static func affine(pairs: [(x: Double, y: Double)]) -> BodyCalibration.Affine? {
        guard pairs.count >= 2 else { return nil }
        let n = Double(pairs.count)
        let sx = pairs.reduce(0) { $0 + $1.x }
        let sy = pairs.reduce(0) { $0 + $1.y }
        let sxx = pairs.reduce(0) { $0 + $1.x * $1.x }
        let sxy = pairs.reduce(0) { $0 + $1.x * $1.y }
        let denom = n * sxx - sx * sx
        guard abs(denom) > 1e-12 else { return nil }
        let slope = (n * sxy - sx * sy) / denom
        let intercept = (sy - slope * sx) / n
        return BodyCalibration.Affine(slope: slope, intercept: intercept)
    }
}

extension CompositionSample {
    var profile: BodyComposer.Profile {
        BodyComposer.Profile(sexMale: sexMale, age: age, heightMeters: heightCm / 100)
    }
}
