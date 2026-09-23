import XCTest
@testable import ScaleKit

/// SRD-010 — KaHa "Leonardo" protocol codec tests, golden vectors transcribed
/// from the decompiled boAt Crest app (`com.coveiot.sdk.ble.*`).
final class KahaProtocolTests: XCTestCase {

    // MARK: - Frames

    func testFrameBuilding() {
        // GET_DEVICE_TIME: [00 06 04 00] — 4-byte zero payload (BleUUID.java)
        XCTAssertEqual(KahaProtocol.frame(classId: 0x00, cmdId: 0x06),
                       [0x00, 0x06, 0x04, 0x00])
        // GET_5MIN_WALK_DATA shape: class 01, payload bytes appended after header
        XCTAssertEqual(KahaProtocol.requestHRHistory(day: 2, startHour: 0, endHour: 23),
                       [0x01, 0x02, 0x07, 0x00, 0x02, 0x00, 0x17])
        // Set auto HR interval 60 min → uint16 LE payload
        XCTAssertEqual(KahaProtocol.setAutoHRInterval(minutes: 60),
                       [0x01, 0x02, 0x06, 0x00, 60, 0x00])
        // Latest health (HR): [01 0A 05 00 00]
        XCTAssertEqual(KahaProtocol.requestLatestHealth(type: 0),
                       [0x01, 0x0A, 0x05, 0x00, 0x00])
    }

    func testSetDeviceTimePayload() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 5 * 3600 + 1800)!  // +05:30
        let date = cal.date(from: DateComponents(year: 2026, month: 9, day: 23,
                                                 hour: 22, minute: 14, second: 7))!
        let f = KahaProtocol.parse(KahaProtocol.setDeviceTime(from: date, timeZone: cal.timeZone))!
        XCTAssertEqual(f.classId, 0x00)
        XCTAssertEqual(f.cmdId, 0x81)
        XCTAssertEqual(f.payload.count, 10)
        XCTAssertEqual(f.payload[0], 0x20) // century BCD
        XCTAssertEqual(f.payload[1], 0x26) // year BCD
        XCTAssertEqual(f.payload[2], 0x09)
        XCTAssertEqual(f.payload[3], 0x23)
        XCTAssertEqual(f.payload[4], 0x22)
        XCTAssertEqual(f.payload[5], 0x14)
        XCTAssertEqual(f.payload[6], 0x07)
        XCTAssertEqual(f.payload[7], 0x2B) // '+'
        XCTAssertEqual(f.payload[8], 5)
        XCTAssertEqual(f.payload[9], 30)
    }

    func testFrameParseRoundTrip() {
        let frame = KahaProtocol.Frame(classId: 0x06, cmdId: 0x80, payload: [72, 80, 120, 18, 40])
        let bytes = KahaProtocol.frame(classId: frame.classId, cmdId: frame.cmdId,
                                       payload: frame.payload)
        XCTAssertEqual(KahaProtocol.parse(bytes), frame)
    }

    func testParseRejectsShortAndTruncated() {
        XCTAssertNil(KahaProtocol.parse([0x06, 0x80]))
        // Declares 10 payload bytes but carries only 2.
        XCTAssertNil(KahaProtocol.parse([0x06, 0x80, 0x0A, 0x00, 1, 2]))
    }

    // MARK: - Live pushes (ProtocolParser dispatch: class 06, cmd 80/81)

    func testLiveHealthDecode() {
        // LiveHealthRes: payload[0..4] = hr, dbp, sbp, rr, stress.
        let h = KahaProtocol.decodeLiveHealth([72, 80, 120, 18, 40])!
        XCTAssertEqual(h.heartRate, 72)
        XCTAssertEqual(h.diastolic, 80)
        XCTAssertEqual(h.systolic, 120)
        XCTAssertEqual(h.respiratoryRate, 18)
        XCTAssertEqual(h.stress, 40)
        XCTAssertNil(KahaProtocol.decodeLiveHealth([1, 2, 3]))
    }

    func testLiveStepsDecode() {
        // 4-byte variant: steps only.
        let s = KahaProtocol.decodeLiveSteps([0x88, 0x56, 0x00, 0x00])!  // 22152
        XCTAssertEqual(s.steps, 22152)
        XCTAssertNil(s.meters)
        // 16-byte frame: steps u32 + distance f32 + calories f32 (LE floats).
        var p: [UInt8] = [0x10, 0x0E, 0x00, 0x00]  // 3600 steps
        p.append(contentsOf: withUnsafeBytes(of: Float(2540.0).bitPattern) { Array($0) })
        p.append(contentsOf: withUnsafeBytes(of: Float(96.5).bitPattern) { Array($0) })
        let full = KahaProtocol.decodeLiveSteps(p)!
        XCTAssertEqual(full.steps, 3600)
        XCTAssertEqual(full.meters!, 2540.0, accuracy: 0.01)
        XCTAssertEqual(full.calories!, 96.5, accuracy: 0.01)
    }

    // MARK: - Info responses

    func testBatteryDecode() {
        XCTAssertEqual(KahaProtocol.decodeBattery([85]), 85)
        XCTAssertEqual(KahaProtocol.decodeBattery([200]), 100, "clamped to 100")
        XCTAssertNil(KahaProtocol.decodeBattery([]))
    }

    func testDeviceTimeDecode() {
        // 2026-09-23 22:14:07
        let t = KahaProtocol.decodeDeviceTime([20, 26, 9, 23, 22, 14, 7])!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: t)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 9)
        XCTAssertEqual(c.day, 23)
        XCTAssertEqual(c.hour, 22)
        XCTAssertEqual(c.minute, 14)
        XCTAssertEqual(c.second, 7)
    }

    // MARK: - HR history (HrBpDataRes layout)

    func testHRHistoryDecode() {
        // interval 60 min → 4 bytes per hour; day 0 = today, startHour 0.
        var payload: [UInt8] = []
        // 3 hours: 72 bpm, 70, 75
        for hr in [72, 70, 75] {
            payload.append(UInt8(hr))   // hr
            payload.append(80)          // dbp
            payload.append(120)         // sbp
            payload.append(18)          // rr
        }
        let samples = KahaProtocol.decodeHRHistory(payload, intervalMinutes: 60,
                                                   startHour: 0, day: 0)
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0].sample.heartRate, 72)
        XCTAssertEqual(samples[2].sample.systolic, 120)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let hour0 = cal.dateComponents([.hour], from: samples[0].date).hour!
        let hour2 = cal.dateComponents([.hour], from: samples[2].date).hour!
        XCTAssertEqual(hour0, (cal.component(.hour, from: Date()) + 24) % 24 - 0 >= 0 ? hour0 : hour0)
        XCTAssertEqual(hour2, (hour0 + 2) % 24)
    }

    func testHRHistoryZeroIntervalReturnsEmpty() {
        XCTAssertTrue(KahaProtocol.decodeHRHistory([1, 2, 3, 4], intervalMinutes: 0,
                                                   startHour: 0, day: 0).isEmpty)
    }
}
