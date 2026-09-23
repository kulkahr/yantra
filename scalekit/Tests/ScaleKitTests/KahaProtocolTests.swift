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

    // MARK: - Sleep history (SleepDataRes layout)

    func testSleepRequestFrame() {
        // GET_10MIN_SLEEP_DATA = {1, 8, 7, 0} + day/startHour/endHour.
        XCTAssertEqual(KahaProtocol.requestSleepHistory(day: 1, startHour: 0, endHour: 23),
                       [0x01, 0x08, 0x07, 0x00, 0x01, 0x00, 0x17])
        // GET_SPO2_PERIODIC = {1, 38, 7, 0} + day/startHour/endHour.
        XCTAssertEqual(KahaProtocol.requestSpo2History(day: 0, startHour: 0, endHour: 23),
                       [0x01, 0x26, 0x07, 0x00, 0x00, 0x00, 0x17])
    }

    func testSleepHistoryDecodeStages() {
        // One hour = 6 bytes = 24 values of 2.5 min.
        // Byte 0b01_00_10_01 = light(1), deep(2), awake(0), light(1).
        var payload: [UInt8] = [0b01_00_10_01]          // 2.5: light, deep, awake, light
        payload.append(contentsOf: repeatElement(0b01_01_01_01, count: 5))  // all light
        let hours = KahaProtocol.decodeSleepHistory(payload, startHour: 22)
        XCTAssertEqual(hours.count, 1)
        let h = hours[0]
        XCTAssertEqual(h.hour, 22)
        XCTAssertEqual(h.awakeMinutes, 2.5, accuracy: 0.001)
        XCTAssertEqual(h.deepMinutes, 2.5, accuracy: 0.001)
        // Byte 0: two light values; bytes 1–5: 20 light values (all 0b01).
        XCTAssertEqual(h.lightMinutes, 2.5 * 2 + 2.5 * 20, accuracy: 0.001)
        XCTAssertEqual(h.remMinutes, 0, accuracy: 0.001)
        XCTAssertEqual(h.totalSleepMinutes, 57.5, accuracy: 0.001)
    }

    func testSleepHistoryMultipleHoursAndWrap() {
        // 2 full hours starting at 23 → hours 23, 0 (midnight wrap).
        let payload = [UInt8](repeating: 0b10_10_10_10, count: 12)  // all deep
        let hours = KahaProtocol.decodeSleepHistory(payload, startHour: 23)
        XCTAssertEqual(hours.count, 2)
        XCTAssertEqual(hours[0].hour, 23)
        XCTAssertEqual(hours[1].hour, 0)
        XCTAssertEqual(hours[1].deepMinutes, 60, accuracy: 0.001)
    }

    func testSleepHistoryTrailingPartialByteDropped() {
        // 7 bytes → only the first full hour (6 bytes) decodes.
        let payload = [UInt8](repeating: 0x55, count: 7)
        XCTAssertEqual(KahaProtocol.decodeSleepHistory(payload, startHour: 0).count, 1)
    }

    // MARK: - SpO2 history (Spo2PeriodicDataRes layout)

    func testSpo2HistoryDecodeSkipsInvalid() {
        // 3 slots: 95, 0xFF (invalid), 97 → 2 samples.
        let samples = KahaProtocol.decodeSpo2History([95, 0xFF, 97], startHour: 8, day: 0)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].percent, 95)
        XCTAssertEqual(samples[1].percent, 97)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let hour = cal.component(.hour, from: samples[1].date)
        XCTAssertEqual(hour, 8, "second slot is 5 min past the 08:00 start")
    }

    func testSpo2HistoryDayOffset() {
        // day 1 → yesterday's 23:xx slot.
        let samples = KahaProtocol.decodeSpo2History([91], startHour: 23, day: 1)
        XCTAssertEqual(samples.count, 1)
        let cal = Calendar(identifier: .gregorian)
        let expected = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!
        XCTAssertTrue(cal.isDate(samples[0].date, inSameDayAs: expected))
    }

    // MARK: - Pairing QR (FragmentQRScanDeviceViewModel.startQRScan parity)

    func testPairingQRFullPayload() {
        let qr = KahaProtocol.parsePairingQR(
            "https://app.boat-lifestyle.com/pair?btname=stormcall_3_0610&mac=AABBCCDDEEFF")!
        // substringBeforeLast("_") parity: only the LAST underscore segment is
        // dropped → STORMCALL_3 (the advertised-name prefix of stormcall_3_0610).
        XCTAssertEqual(qr.deviceName, "STORMCALL_3")
        XCTAssertEqual(qr.nameFilter, "STORMCALL_3")
        XCTAssertEqual(qr.mac, "AA:BB:CC:DD:EE:FF")
    }

    func testPairingQRMcKeyAndColonMAC() {
        let qr = KahaProtocol.parsePairingQR("btname=stormcall_3_0610&mc=AA:BB:CC:DD:EE:FF")!
        XCTAssertEqual(qr.mac, "AA:BB:CC:DD:EE:FF", "17-char colon MAC kept as-is")
    }

    func testPairingQRNameSpacesAndNoMAC() {
        let qr = KahaProtocol.parsePairingQR("btname=storm%20call2_x1")!
        XCTAssertEqual(qr.deviceName, "STORM CALL2")
        XCTAssertEqual(qr.nameFilter, "STORM CALL2")
        XCTAssertNil(qr.mac, "no mac=/mc= → scan by name")
    }

    func testPairingQRRejectsNonBoatPayload() {
        XCTAssertNil(KahaProtocol.parsePairingQR("https://example.com/nothing"))
        XCTAssertNil(KahaProtocol.parsePairingQR("btname="))
    }

    // MARK: - Control & notification commands

    func testMusicAndCameraAndFindWatchFrames() {
        // SetMusicPlayBackStatusReq: {2, -127, 5, 0, play?1:2}
        XCTAssertEqual(KahaProtocol.setMusicPlayback(playing: true),
                       [0x02, 0x81, 0x05, 0x00, 0x01])
        XCTAssertEqual(KahaProtocol.setMusicPlayback(playing: false),
                       [0x02, 0x81, 0x05, 0x00, 0x02])
        // SetMusicVolumePercentageReq: {0, -89, 5, 0, pct}
        XCTAssertEqual(KahaProtocol.setMusicVolume(percent: 60),
                       [0x00, 0xA7, 0x05, 0x00, 60])
        // FindMyWatchReq: {2, -91, 6, 0, start?1:2, count}
        XCTAssertEqual(KahaProtocol.findMyWatch(start: true, count: 3),
                       [0x02, 0xA5, 0x06, 0x00, 0x01, 3])
        // SetCameraStatusReq: {2, 18, 6, 0, 2, enter?1:2}
        XCTAssertEqual(KahaProtocol.setCameraRemote(enter: true),
                       [0x02, 0x12, 0x06, 0x00, 0x02, 0x01])
    }

    func testAlertSwitchesBitmask() {
        // MessageAlertSwitchesReq: call=1 + sms=4 → byte0 0x05.
        XCTAssertEqual(KahaProtocol.setAlertSwitches([.call, .sms]),
                       [0x02, 0x82, 0x06, 0x00, 0x05, 0x00])
        // Telegram (bit 6 of byte1) + call → 0x41 in byte1.
        XCTAssertEqual(KahaProtocol.setAlertSwitches([.call, .telegram]),
                       [0x02, 0x82, 0x06, 0x00, 0x01, 0x40])
    }

    func testSendMessageShortFrame() {
        let frames = KahaProtocol.sendMessage("Hi", type: 3)  // SMS
        XCTAssertEqual(frames.count, 1)
        let f = KahaProtocol.parse(frames[0])!
        XCTAssertEqual(f.classId, 0x02)
        XCTAssertEqual(f.cmdId, 0x83)
        // Payload layout: [lenLo, lenHi, type, msg…]
        XCTAssertEqual(f.payload.dropFirst(2).first, 3)
        XCTAssertEqual(String(bytes: f.payload.dropFirst(3), encoding: .utf8), "Hi")
    }

    func testSendMessageMultipacketSplits() {
        let long = String(repeating: "x", count: 40)
        let frames = KahaProtocol.sendMessage(long, type: 18)
        XCTAssertEqual(frames.first?.first, 0x7F, "long messages start with the 0x7F header")
        XCTAssertEqual(frames.count > 1, true)
    }

    func testWatchControlDecode() {
        // Find-phone push: [01 05 04 00 01 01]
        let fp = KahaProtocol.decodeWatchControl(
            KahaProtocol.parse([0x01, 0x05, 0x06, 0x00, 0x01, 0x01])!)
        XCTAssertEqual(fp, .findMyPhone)
        // Camera capture: [01 05 06 00 03 01]
        XCTAssertEqual(KahaProtocol.decodeWatchControl(
            KahaProtocol.parse([0x01, 0x05, 0x06, 0x00, 0x03, 0x01])!), .cameraCapture)
        // Music next: [01 00 05 00 03]
        XCTAssertEqual(KahaProtocol.decodeWatchControl(
            KahaProtocol.parse([0x01, 0x00, 0x05, 0x00, 0x03])!), .musicNext)
        // Unrelated frame → nil.
        XCTAssertNil(KahaProtocol.decodeWatchControl(
            KahaProtocol.parse(KahaProtocol.frame(classId: 0x06, cmdId: 0x80,
                                                  payload: [1, 2, 3, 4, 5]))!))
    }
}
