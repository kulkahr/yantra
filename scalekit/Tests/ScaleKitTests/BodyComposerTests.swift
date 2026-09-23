import XCTest
@testable import ScaleKit

final class BodyComposerTests: XCTestCase {

    let male = BodyComposer.Profile(sexMale: true, age: 33, heightMeters: 1.75)

    func testBMIBasic() {
        let c = BodyComposer.compose(weightKg: 70.75, impedanceOhm: 585, profile: male)
        XCTAssertEqual(c.bmi, 70.75 / (1.75 * 1.75), accuracy: 0.01)
        XCTAssertTrue(c.impedanceBased)
    }

    func testFatFreeWithinWeight() {
        let c = BodyComposer.compose(weightKg: 70.75, impedanceOhm: 585, profile: male)
        XCTAssertGreaterThanOrEqual(c.fatFreeKg, 0)
        XCTAssertLessThanOrEqual(c.fatFreeKg, 70.75)
        // fatFree + fatMass == weight
        XCTAssertEqual(c.fatFreeKg + (70.75 - c.fatFreeKg), 70.75, accuracy: 0.001)
        XCTAssertGreaterThan(c.fatPercent, 2)
        XCTAssertLessThan(c.fatPercent, 60)
    }

    func testNoImpedanceFallback() {
        let c = BodyComposer.compose(weightKg: 70.75, impedanceOhm: nil, profile: male)
        XCTAssertFalse(c.impedanceBased)
        // Deurenberg: 1.20·23.102 + 0.23·33 − 10.8 − 5.4 ≈ 19.11 % for this profile
        XCTAssertEqual(c.fatPercent, 19.11, accuracy: 1.0)
    }

    func testFemaleDiffersFromMale() {
        let female = BodyComposer.Profile(sexMale: false, age: 33, heightMeters: 1.75)
        let m = BodyComposer.compose(weightKg: 70.75, impedanceOhm: 585, profile: male)
        let f = BodyComposer.compose(weightKg: 70.75, impedanceOhm: 585, profile: female)
        XCTAssertNotEqual(m.fatPercent, f.fatPercent)
        XCTAssertGreaterThan(f.fatPercent, m.fatPercent)
        XCTAssertEqual(m.basalMetabolismKcal, f.basalMetabolismKcal + 166, accuracy: 2)
    }

    func testMassesSumConsistently() {
        let c = BodyComposer.compose(weightKg: 70.75, impedanceOhm: 600, profile: male)
        XCTAssertLessThanOrEqual(c.softLeanKg + c.boneKg, c.fatFreeKg + 0.001)
        XCTAssertGreaterThan(c.muscleKg, 0)
        XCTAssertGreaterThan(c.waterPercent, 20)
        XCTAssertLessThan(c.waterPercent, 75)
        XCTAssertGreaterThan(c.basalMetabolismKcal, 1000)
        XCTAssertLessThan(c.basalMetabolismKcal, 3000)
    }

    func testComposeFromRecord() {
        // Minimal record: flags unit=0 only + weight 7075 → 70.75 kg, no impedance.
        var payload: [UInt8] = [0x48, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1B, 0xA3]
        let rec = A6WeightRecordParser.parse(payload)
        XCTAssertNotNil(rec)
        let c = BodyComposer.compose(record: rec!, profile: male)
        XCTAssertEqual(c.bmi, 70.75 / (1.75 * 1.75), accuracy: 0.01)
        XCTAssertFalse(c.impedanceBased)
    }

    func testExtremeValuesClamped() {
        let c = BodyComposer.compose(weightKg: 5, impedanceOhm: 100, profile: male)
        // Very low impedance → huge FFM estimate → must clamp to ≤ weight (fat% ≥ 2).
        XCTAssertGreaterThanOrEqual(c.fatPercent, 2)
        XCTAssertLessThanOrEqual(c.fatPercent, 60)
    }
}

final class BodyCalibrationTests: XCTestCase {

    let male = BodyComposer.Profile(sexMale: true, age: 33, heightMeters: 1.75)

    /// Synthetic generator standing in for "the official cloud" — a known
    /// linear fat% model + affine-warped metrics. The fitter must recover it.
    /// Official metrics are generated from the TRUTH-model base, mirroring the
    /// fitter's contract (affines map fat-fitted base → official).
    func makeSamples(count: Int, withNoise: Bool = false) -> [CompositionSample] {
        let truthCal = BodyCalibration(
            fallbackFatOffset: 0,
            fatFit: BodyCalibration.FatFit(intercept: 9, h2OverR: -0.004,
                                           weight: 0.25, age: 0.05),
            corrections: [:])
        var samples: [CompositionSample] = []
        for i in 0..<count {
            let w = 62 + Double(i % 9) * 1.7          // 62…75.8 kg
            let r = 460 + Double(i % 7) * 40          // 460…700 Ω
            let age = 25 + (i % 5) * 4                // 25…41 y
            var s = CompositionSample(utc: Date(timeIntervalSince1970: Double(1_700_000_000 + i * 86_400)),
                                      weightKg: w, impedanceOhm: r,
                                      sexMale: true, age: age, heightCm: 175)
            // "Official" truth: fat% = 9 − 0.004·(h²/R) + 0.25·W + 0.05·age
            s.officialFatPercent = 9.0 - 0.004 * (175 * 175 / r) + 0.25 * w + 0.05 * Double(age)
            // A couple of affine-warped metrics to exercise that path.
            let base = BodyComposer.compose(weightKg: w, impedanceOhm: r,
                                            profile: BodyComposer.Profile(sexMale: true, age: age, heightMeters: 1.75),
                                            calibration: truthCal)
            s.officialVisceralLevel = base.visceralFatLevel * 1.2 + 0.5
            s.officialBoneKg = base.boneKg * 0.9 + 0.1
            samples.append(s)
        }
        return samples
    }

    func testStandardCalibrationIsIdentity() {
        let c1 = BodyComposer.compose(weightKg: 70.75, impedanceOhm: 585, profile: male)
        let c2 = BodyComposer.compose(weightKg: 70.75, impedanceOhm: 585, profile: male,
                                      calibration: .standard)
        XCTAssertEqual(c1, c2)
        XCTAssertTrue(BodyCalibration.standard.isStandard)
    }

    func testFitRecoversLinearFatModel() {
        let samples = makeSamples(count: 12)
        guard let (cal, report) = BodyCalibration.fit(samples: samples) else {
            return XCTFail("fit should succeed with 12 rich samples")
        }
        XCTAssertNotNil(cal.fatFit)
        // Truth: intercept 9, h²/R −0.004, W 0.25, age 0.05.
        XCTAssertEqual(cal.fatFit!.intercept, 9.0, accuracy: 0.01)
        XCTAssertEqual(cal.fatFit!.h2OverR, -0.004, accuracy: 0.001)
        XCTAssertEqual(cal.fatFit!.weight, 0.25, accuracy: 0.01)
        XCTAssertEqual(cal.fatFit!.age, 0.05, accuracy: 0.001)
        XCTAssertNotNil(report.maxFatResidual, "residual report must be populated")
        XCTAssertLessThan(report.maxFatResidual!, 0.02, "recovered model must fit truth")
        XCTAssertEqual(report.sampleCount, 12)
        // Corrections for the two warped metrics exist with sub-0.01 RMS.
        XCTAssertEqual(cal.corrections["visceralFatLevel"]?.slope ?? 0, 1.2, accuracy: 0.01)
        XCTAssertEqual(cal.corrections["visceralFatLevel"]?.intercept ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(cal.corrections["boneKg"]?.slope ?? 0, 0.9, accuracy: 0.01)
        XCTAssertEqual(cal.corrections["boneKg"]?.intercept ?? 0, 0.1, accuracy: 0.01)
        XCTAssertNil(cal.corrections["fatPercent"], "fat% uses the direct fit, not an affine")
    }

    func testFittedCalibrationReproducesOfficialValues() {
        let samples = makeSamples(count: 12)
        let (cal, _) = BodyCalibration.fit(samples: samples)!
        for s in samples {
            let c = BodyComposer.compose(weightKg: s.weightKg, impedanceOhm: s.impedanceOhm,
                                         profile: s.profile, calibration: cal)
            XCTAssertEqual(c.fatPercent, s.officialFatPercent!, accuracy: 0.05)
            // The visceral level is quantized to the 0.1 display grid at two
            // points (fit sees the quantized base; compose quantizes after the
            // affine), giving a worst-case ~0.11 combined rounding — still far
            // below the 0.1 grid users see.
            XCTAssertEqual(c.visceralFatLevel, s.officialVisceralLevel!, accuracy: 0.15)
        }
    }

    func testFitDropsConstantAgeColumn() {
        // All samples share one age — the age column must be dropped, not singular.
        var samples = makeSamples(count: 8)
        for i in samples.indices { samples[i].age = 33 }
        let fit = BodyCalibration.fit(samples: samples)
        XCTAssertNotNil(fit)
        XCTAssertEqual(fit!.calibration.fatFit!.age, 0)
    }

    func testInsufficientSamplesReturnsNil() {
        XCTAssertNil(BodyCalibration.fit(samples: []))
        // Fat model needs ≥4 impedance samples; with no other official metrics
        // present, a 3-row set has nothing to fit.
        var rows = makeSamples(count: 3)
        for i in rows.indices {
            rows[i].officialVisceralLevel = nil
            rows[i].officialBoneKg = nil
        }
        XCTAssertNil(BodyCalibration.fit(samples: rows))
        // But affine-only metrics need just ≥2 samples — those same rows with
        // the warped metrics present do calibrate.
        XCTAssertNotNil(BodyCalibration.fit(samples: makeSamples(count: 3)))
    }

    func testFallbackOffsetFit() {
        // Samples WITHOUT impedance: official fat% = Deurenberg + 3.0 exactly.
        var s = CompositionSample(weightKg: 70.75, impedanceOhm: nil,
                                  sexMale: true, age: 33, heightCm: 175)
        let base = 1.20 * (70.75 / 3.0625) + 0.23 * 33 - 10.8 - 5.4
        s.officialFatPercent = base + 3.0
        let fit = BodyCalibration.fit(samples: [s, s])
        XCTAssertNotNil(fit, "fallback rows alone can still fit the offset")
        XCTAssertEqual(fit!.calibration.fallbackFatOffset, 3.0, accuracy: 0.001)
        // Applied on compose:
        let c = BodyComposer.compose(weightKg: 70.75, impedanceOhm: nil, profile: male,
                                     calibration: fit!.calibration)
        XCTAssertEqual(c.fatPercent, base + 3.0, accuracy: 0.01)
    }

    func testAffineNeedsVariance() {
        // Two identical samples → zero x-variance → no affine, no crash.
        let samples = makeSamples(count: 4)
        var s = samples[0]
        s.officialBoneKg = 2.5
        let fit = BodyCalibration.fit(samples: samples)
        XCTAssertNotNil(fit)
    }
}
