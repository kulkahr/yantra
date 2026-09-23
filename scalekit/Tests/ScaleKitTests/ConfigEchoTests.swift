import XCTest
@testable import ScaleKit

final class ConfigEchoTests: XCTestCase {

    // MARK: 0x2001 user-info echo

    func makeUserInfoPayload(slot: Int = 2, sexMale: Bool = false, age: Int = 28,
                             heightCm: Int = 165, athlete: Bool = false,
                             activity: Int = 1, weightKg: Double? = nil) -> [UInt8] {
        var p = A6Bytes.from(short: 0x2001)
        p.append(UInt8(slot))
        p.append(sexMale ? 0 : 1)
        p.append(UInt8(age))
        p += A6Bytes.from(short: UInt16(heightCm))
        p.append(athlete ? 1 : 0)
        p.append(UInt8(activity))
        if let w = weightKg {
            p += A6Bytes.from(short: UInt16((w * 100).rounded()))
        } else {
            p += [0xFF, 0xFF]
        }
        return p
    }

    func testParseUserInfoEcho() {
        let e = ConfigEcho.parseUserInfo(makeUserInfoPayload())
        XCTAssertNotNil(e)
        XCTAssertEqual(e?.slot, 2)
        XCTAssertEqual(e?.sexMale, false)
        XCTAssertEqual(e?.age, 28)
        XCTAssertEqual(e?.heightCm, 165)
        XCTAssertEqual(e?.weightKg, nil)
    }

    func testVerifyUserInfoEchoMatches() {
        let echo = ConfigEcho.parseUserInfo(makeUserInfoPayload())!
        let mismatches = ConfigEcho.verify(echo, slot: 2, sexMale: false,
                                           age: 28, heightMeters: 1.65)
        XCTAssertTrue(mismatches.isEmpty)
    }

    func testVerifyUserInfoEchoDetectsMismatch() {
        // Scale echoed slot/sex/age/height different from what we pushed.
        let echo = ConfigEcho.parseUserInfo(
            makeUserInfoPayload(slot: 1, sexMale: true, age: 40, heightCm: 170))!
        let m = ConfigEcho.verify(echo, slot: 2, sexMale: false, age: 28, heightMeters: 1.65)
        XCTAssertEqual(m.count, 4, "slot, sex, age and height all differ: \(m)")
    }

    func testSettingCallbackParsing() {
        let accepted = ConfigEcho.parseSettingCallback([0x10, 0x00, 0x04, 0x01])
        XCTAssertEqual(accepted?.configType, 0x04)
        XCTAssertEqual(accepted?.accepted, true)
        let rejected = ConfigEcho.parseSettingCallback([0x10, 0x00, 0x02, 0x00])
        XCTAssertEqual(rejected?.accepted, false)
        XCTAssertNil(ConfigEcho.parseSettingCallback([0x10, 0x00]))
    }

    // MARK: 0x2004 unit echo

    func testUnitEcho() {
        XCTAssertEqual(ConfigEcho.parseUnit([0x20, 0x04, 0x00]), .kg)
        XCTAssertEqual(ConfigEcho.parseUnit([0x20, 0x04, 0x01]), .lb)
        XCTAssertNil(ConfigEcho.parseUnit([0x20, 0x04]))
        XCTAssertNil(ConfigEcho.parseUnit([0x20, 0x04, 0x77]))
    }

    // MARK: 0x2003 target echo

    func testTargetEcho() {
        var p = A6Bytes.from(short: 0x2003)
        p.append(1)             // slot
        p.append(1)             // enabled
        p += A6Bytes.from(int: 6_500)   // 65.00 kg
        let e = ConfigEcho.parseTarget(p)
        XCTAssertEqual(e?.slot, 1)
        XCTAssertEqual(e?.enabled, true)
        XCTAssertEqual(e?.targetKg, 65.0)
        let m = ConfigEcho.verify(e!, slot: 1, targetKg: 65.0)
        XCTAssertTrue(m.isEmpty)
        // Wrong value → mismatch.
        let m2 = ConfigEcho.verify(e!, slot: 1, targetKg: 70.0)
        XCTAssertFalse(m2.isEmpty)
    }

    // MARK: 0x1006 formula / 0x1003 disabled-target frames

    func testFormulaFrame() {
        XCTAssertEqual(A6Commands.pushFormula(.china), [0x10, 0x06, 0x00])
        XCTAssertEqual(A6Commands.pushFormula(.external), [0x10, 0x06, 0x01])
    }

    func testTargetDisabledFrame() {
        XCTAssertEqual(A6Commands.pushTargetDisabled(slot: 3),
                       [0x10, 0x03, 0x03, 0x00, 0x00, 0x00, 0x00])
    }

    // MARK: Battery (SRD-006 FR-3) — raw byte IS the percent (issue #15)

    func testBatteryMapping() {
        XCTAssertEqual(Battery.percent(rawByte: 0), 0)
        XCTAssertEqual(Battery.percent(rawByte: 80), 80)
        XCTAssertEqual(Battery.percent(rawByte: 100), 100)
        XCTAssertEqual(Battery.percent(rawByte: 200), 100, "clamped to 100")
        XCTAssertTrue(Battery.isLow(rawByte: 10), "DFU gate: ≤10 %% is low")
        XCTAssertTrue(Battery.isLow(rawByte: 5))
        XCTAssertFalse(Battery.isLow(rawByte: 60))
        // Informational volts estimate retained.
        XCTAssertEqual(Battery.volts(rawByte: 100), 2.6, accuracy: 0.001)
    }
}
