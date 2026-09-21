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
