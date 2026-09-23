import Foundation

/// KaHa "Leonardo" BLE protocol for the boAt Storm Call 3 (SRD-010).
///
/// Reverse-engineered from the boAt Crest APK (`com.coveiot.android.boat`),
/// classes `com.coveiot.sdk.ble.api.BleUUID` (command constants), `ProtocolParser`
/// (response dispatch), `LiveHealthRes`/`LiveStepsRes`/`HrBpDataRes`/`GetTimeRes`
/// (payload layouts). Documented in `docs/SRD-010-Watch-Integration.md`.
///
/// Transport: Nordic-UART service `6E400001-…` — write commands to `6E400002-…`,
/// receive notifications on `6E400003-…`.
///
/// Frame: `[classId, cmdId, lenLo, lenHi, payload…]` — no checksum, no auth.
/// Responses arrive with class id = request id | 0x80 (live-data class `0x06`
/// keeps `0x06` in both directions; `0x7F` marks multipacket continuations).
public enum KahaProtocol {

    // MARK: - GATT UUIDs (BleUUID.java)

    public enum GATT {
        public static let uartService = UUID(uuidString: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")!
        public static let uartWrite   = UUID(uuidString: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")!
        public static let uartRead    = UUID(uuidString: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")!
        public static let batteryService = UUID(uuidString: "0000180F-0000-1000-8000-00805F9B34FB")!
        public static let batteryLevel   = UUID(uuidString: "00002A19-0000-1000-8000-00805F9B34FB")!
        public static let deviceInfoService = UUID(uuidString: "0000180A-0000-1000-8000-00805F9B34FB")!
        public static let firmwareRevision  = UUID(uuidString: "00002A26-0000-1000-8000-00805F9B34FB")!
    }

    // MARK: - Command ids (BleUUID.java constants)

    public enum ClassId {
        public static let info: UInt8 = 0x00          // device info & settings
        public static let fitness: UInt8 = 0x01       // health/fitness data
        public static let alerts: UInt8 = 0x02        // notifications/alarms
        public static let system: UInt8 = 0x06        // system control
        public static let live: UInt8 = 0x06          // live-data push class (same byte, response side)
        public static let multipacket: UInt8 = 0x7F   // response continuation header
    }

    public enum InfoCmd {
        public static let getDeviceName: UInt8 = 0x00
        public static let getHardwareVersion: UInt8 = 0x01
        public static let getFirmwareVersion: UInt8 = 0x02
        public static let getDeviceTime: UInt8 = 0x06
        public static let getBatteryLevel: UInt8 = 0x08
        public static let set24HourFormat: UInt8 = 0x79
        public static let setDeviceTime: UInt8 = 0x81   // 0x80|1
    }

    public enum FitnessCmd {
        public static let hrBpInterval: UInt8 = 0x02    // set auto-measure interval / request history
        public static let latestHealth: UInt8 = 0x0A    // payload byte: 0 HR, 1 SpO2, 2 temp, 3 BP
        public static let sleepHistory: UInt8 = 0x08    // 10-min sleep data (GET_10MIN_SLEEP_DATA)
        public static let spo2History: UInt8 = 0x26     // periodic SpO2 (GET_SPO2_PERIODIC)
        public static let todaysFitness: UInt8 = 0x2F
    }

    public enum LiveCmd {
        public static let liveHealth: UInt8 = 0x80      // hr, dbp, sbp, rr, stress
        public static let liveSteps: UInt8 = 0x81       // steps u32 LE [+ distance f32 + calories f32]
    }

    // MARK: - Frame building

    /// Builds a request frame `[classId, cmdId, lenLo, lenHi, payload…]`.
    /// The length field is the TOTAL frame length (header + payload) —
    /// decompiled parity: `GET_DEVICE_TIME = {0, 6, 4, 0}` (no payload → 4),
    /// `SET_DEVICE_TIME = {0, 0x81, 14, 0}` + 10 payload bytes (4 + 10 = 14).
    public static func frame(classId: UInt8, cmdId: UInt8, payload: [UInt8] = []) -> [UInt8] {
        let len = 4 + payload.count
        return [classId, cmdId, UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF)] + payload
    }

    /// `GET_DEVICE_NAME` etc. — 4-byte zero-payload info requests.
    public static func infoFrame(cmdId: UInt8) -> [UInt8] {
        frame(classId: ClassId.info, cmdId: cmdId)
    }

    /// `0x01 0x02` set-auto-HR-interval, minutes uint16 LE.
    public static func setAutoHRInterval(minutes: Int) -> [UInt8] {
        frame(classId: ClassId.fitness, cmdId: FitnessCmd.hrBpInterval,
              payload: [UInt8(minutes & 0xFF), UInt8((minutes >> 8) & 0xFF)])
    }

    /// `0x01 0x02` history request — `day startHour endHour`
    /// (day = days ago, 0 = today; mirrors `HeartRateBpReq`).
    public static func requestHRHistory(day: Int, startHour: Int, endHour: Int) -> [UInt8] {
        frame(classId: ClassId.fitness, cmdId: FitnessCmd.hrBpInterval,
              payload: [UInt8(day), UInt8(startHour), UInt8(endHour)])
    }

    /// `0x01 0x08` 10-min sleep history — `day startHour endHour`
    /// (`GET_10MIN_SLEEP_DATA` + `RequestPayload` day/hours, per `SleepDataReq`).
    public static func requestSleepHistory(day: Int, startHour: Int, endHour: Int) -> [UInt8] {
        frame(classId: ClassId.fitness, cmdId: FitnessCmd.sleepHistory,
              payload: [UInt8(day), UInt8(startHour), UInt8(endHour)])
    }

    /// `0x01 0x26` periodic SpO2 history — `day startHour endHour`
    /// (`GET_SPO2_PERIODIC` + `RequestPayload`, per `PeriodicSPO2BaseReq`).
    public static func requestSpo2History(day: Int, startHour: Int, endHour: Int) -> [UInt8] {
        frame(classId: ClassId.fitness, cmdId: FitnessCmd.spo2History,
              payload: [UInt8(day), UInt8(startHour), UInt8(endHour)])
    }

    /// `0x01 0x0A` latest health sample request (`type`: 0 HR, 1 SpO2, 2 temp, 3 BP).
    public static func requestLatestHealth(type: UInt8) -> [UInt8] {
        frame(classId: ClassId.fitness, cmdId: FitnessCmd.latestHealth, payload: [type])
    }

    /// `0x00 0x81` device-time set — yyyy(2 BCD) MM dd HH mm ss ±HH mm (10 bytes),
    /// byte-for-byte the layout `LeonardoBleService.k()` sends.
    public static func setDeviceTime(from date: Date, timeZone: TimeZone = .current) -> [UInt8] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let y = c.year ?? 2000
        let offsetMinutes = timeZone.secondsFromGMT(for: date) / 60
        let sign: UInt8 = offsetMinutes >= 0 ? 0x2B /* + */ : 0x2D /* - */
        let ah = abs(offsetMinutes) / 60, am = abs(offsetMinutes) % 60
        func bcd(_ v: Int) -> UInt8 { UInt8(((v / 10) << 4) | (v % 10)) }
        let yy = y % 100
        return frame(classId: ClassId.info, cmdId: InfoCmd.setDeviceTime, payload: [
            bcd(y / 100), bcd(yy), bcd(c.month ?? 1), bcd(c.day ?? 1),
            bcd(c.hour ?? 0), bcd(c.minute ?? 0), bcd(c.second ?? 0),
            sign, UInt8(ah), UInt8(am),
        ])
    }

    // MARK: - Frame parsing

    /// One parsed notification frame.
    public struct Frame: Equatable {
        public var classId: UInt8
        public var cmdId: UInt8
        public var payload: [UInt8]

        /// `0x7F` multipacket header: total packet count at payload[0..1] LE
        /// (ProtocolParser reads bArr[4]/bArr[5] — the first two payload bytes).
        public var multipacketTotal: Int? {
            guard classId == ClassId.multipacket, payload.count >= 2 else { return nil }
            return Int(payload[0]) | (Int(payload[1]) << 8)
        }
    }

    /// Parses one notification into a `Frame` (nil when too short / length mismatch).
    /// The length field is the total frame length, matching the request side.
    public static func parse(_ bytes: [UInt8]) -> Frame? {
        guard bytes.count >= 4 else { return nil }
        let total = Int(bytes[2]) | (Int(bytes[3]) << 8)
        guard total >= 4, bytes.count >= total else { return nil }
        return Frame(classId: bytes[0], cmdId: bytes[1], payload: Array(bytes[4..<total]))
    }

    // MARK: - Payload decoders

    /// Live health push `06 80`: hr, dbp, sbp, rr, stress (`LiveHealthRes`).
    public struct LiveHealth: Equatable {
        public var heartRate: Int
        public var diastolic: Int
        public var systolic: Int
        public var respiratoryRate: Int
        public var stress: Int
    }

    public static func decodeLiveHealth(_ payload: [UInt8]) -> LiveHealth? {
        guard payload.count >= 5 else { return nil }
        return LiveHealth(heartRate: Int(payload[0]), diastolic: Int(payload[1]),
                          systolic: Int(payload[2]), respiratoryRate: Int(payload[3]),
                          stress: Int(payload[4]))
    }

    /// Live steps push `06 81`: steps u32 LE; 12-byte payload variant adds
    /// float32 distance (meters) + float32 calories (`LiveStepsRes`).
    public struct LiveSteps: Equatable {
        public var steps: Int
        public var meters: Double?
        public var calories: Double?
    }

    public static func decodeLiveSteps(_ payload: [UInt8]) -> LiveSteps? {
        guard payload.count >= 4 else { return nil }
        let steps = Int(payload[0]) | (Int(payload[1]) << 8)
            | (Int(payload[2]) << 16) | (Int(payload[3]) << 24)
        var out = LiveSteps(steps: steps, meters: nil, calories: nil)
        if payload.count >= 12 {
            out.meters = Double(leFloat(payload, 4))
            out.calories = Double(leFloat(payload, 8))
        }
        return out
    }

    /// Battery response `00 88`: single percent byte (`ReadBatteryLevelRes`).
    public static func decodeBattery(_ payload: [UInt8]) -> Int? {
        guard let first = payload.first else { return nil }
        return min(100, max(0, Int(first)))
    }

    /// Device-time response `00 86`: yyyy(2) MM dd HH mm ss (`GetTimeRes`).
    public static func decodeDeviceTime(_ payload: [UInt8],
                                        timeZone: TimeZone = .current) -> Date? {
        guard payload.count >= 6 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let year = Int(payload[0]) * 100 + Int(payload[1])
        return cal.date(from: DateComponents(year: year, month: Int(payload[2]),
                                             day: Int(payload[3]), hour: Int(payload[4]),
                                             minute: Int(payload[5]), second: payload.count > 6 ? Int(payload[6]) : 0))
    }

    /// One HR/BP history sample (4 bytes: hr, dbp, sbp, rr — `HrBpDataRes`).
    public struct HRSample: Equatable {
        public var heartRate: Int
        public var diastolic: Int
        public var systolic: Int
        public var respiratoryRate: Int
    }

    /// Decodes a history day: samples-per-hour = (60/interval)×4 bytes per hour,
    /// hour 0 = `startHour`. `interval` is the minutes-per-sample setting.
    public static func decodeHRHistory(_ payload: [UInt8], intervalMinutes: Int,
                                       startHour: Int, day: Int,
                                       timeZone: TimeZone = .current) -> [(date: Date, sample: HRSample)] {
        let perHour = intervalMinutes > 0 ? (60 / intervalMinutes) * 4 : 0
        guard perHour > 0 else { return [] }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard let base = cal.date(byAdding: .day, value: -day, to: Date()) else { return [] }
        let dayStart = cal.startOfDay(for: base)
        var out: [(Date, HRSample)] = []
        var offset = 0
        while offset + 4 <= payload.count {
            let sample = HRSample(heartRate: Int(payload[offset]), diastolic: Int(payload[offset + 1]),
                                  systolic: Int(payload[offset + 2]), respiratoryRate: Int(payload[offset + 3]))
            let sampleIndex = offset / 4
            let hour = startHour + sampleIndex / perHour
            let minute = (sampleIndex % perHour) * intervalMinutes
            if let date = cal.date(byAdding: .minute, value: hour * 60 + minute, to: dayStart) {
                out.append((date, sample))
            }
            offset += 4
        }
        return out
    }

    // MARK: - Sleep history (SleepDataRes layout)

    /// Sleep stage per 2-bit packed value (SleepDataRes counters:
    /// 0 → awake, 1 → light, 2 → deep, 3 → REM).
    public enum SleepStage: Int, Codable, CaseIterable {
        case awake = 0
        case light = 1
        case deep = 2
        case rem = 3
    }

    /// One hour of sleep, aggregated into minutes per stage.
    public struct SleepHour: Equatable, Codable {
        public var hour: Int                 // 0–23, watch-local day
        public var awakeMinutes: Double
        public var lightMinutes: Double
        public var deepMinutes: Double
        public var remMinutes: Double

        public init(hour: Int, awakeMinutes: Double, lightMinutes: Double,
                    deepMinutes: Double, remMinutes: Double) {
            self.hour = hour
            self.awakeMinutes = awakeMinutes
            self.lightMinutes = lightMinutes
            self.deepMinutes = deepMinutes
            self.remMinutes = remMinutes
        }

        public var totalSleepMinutes: Double { lightMinutes + deepMinutes + remMinutes }
    }

    /// Decodes 10-min sleep history (`0x01 0x08` response).
    ///
    /// Wire layout (SleepDataRes): 6 bytes per hour starting at `startHour`;
    /// each byte packs FOUR 2-bit stage values of 2.5 min each (4 × 2.5 = the
    /// byte's 10-minute window). Aggregates into per-hour stage minutes.
    public static func decodeSleepHistory(_ payload: [UInt8], startHour: Int) -> [SleepHour] {
        let bytesPerHour = 6
        let valuesPerByte = 4
        let minutesPerValue = 10.0 / Double(valuesPerByte)
        var out: [SleepHour] = []
        var offset = 0
        var hour = startHour
        while offset + bytesPerHour <= payload.count {
            var awake = 0.0, light = 0.0, deep = 0.0, rem = 0.0
            for b in offset..<(offset + bytesPerHour) {
                let byte = payload[b]
                for shift in [6, 4, 2, 0] {
                    let v = Int((byte >> UInt8(shift)) & 0x03)
                    switch SleepStage(rawValue: v) {
                    case .awake: awake += minutesPerValue
                    case .light: light += minutesPerValue
                    case .deep: deep += minutesPerValue
                    case .rem: rem += minutesPerValue
                    case .none: break
                    }
                }
            }
            out.append(SleepHour(hour: hour % 24, awakeMinutes: awake,
                                 lightMinutes: light, deepMinutes: deep, remMinutes: rem))
            offset += bytesPerHour
            hour += 1
        }
        return out
    }

    // MARK: - SpO2 history (Spo2PeriodicDataRes layout)

    /// One periodic SpO2 sample (5-minute slot).
    public struct SpO2Sample: Equatable, Codable {
        public var date: Date
        public var percent: Int

        public init(date: Date, percent: Int) {
            self.date = date
            self.percent = percent
        }
    }

    /// Decodes periodic SpO2 history (`0x01 0x26` response): one byte per
    /// 5-minute slot from `startHour`; `0xFF` = no reading (Spo2PeriodicDataRes
    /// filters `-1` bytes). `day` = days ago for the sample's date.
    public static func decodeSpo2History(_ payload: [UInt8], startHour: Int, day: Int,
                                         timeZone: TimeZone = .current) -> [SpO2Sample] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard let base = cal.date(byAdding: .day, value: -day, to: Date()) else { return [] }
        let dayStart = cal.startOfDay(for: base)
        var out: [SpO2Sample] = []
        for (i, b) in payload.enumerated() where b != 0xFF {
            let minute = startHour * 60 + i * 5
            if let date = cal.date(byAdding: .minute, value: minute, to: dayStart) {
                out.append(SpO2Sample(date: date, percent: Int(b)))
            }
        }
        return out
    }

    // MARK: - Pairing QR payload (FragmentQRScanDeviceViewModel.startQRScan)

    /// Decoded boAt pairing QR — the code shown by the watch's "pair" screen
    /// and scanned by the official app's camera (ML-kit barcode, format 256 =
    /// QR). Format: `...btname=<NAME>...mac=<MAC>|mc=<MAC>...` (case-insensitive
    /// keys, name may carry `%20` for spaces and trailing `_<suffix>`).
    public struct PairingQR: Equatable {
        /// Advertised device name, underscore suffix stripped (`stormcall_3_0610` → `stormcall`).
        public var deviceName: String
        /// The name filter to match advertisements against (uppercase, spaces restored).
        public var nameFilter: String
        /// MAC address colon-normalized to `AA:BB:CC:DD:EE:FF` (nil when the QR
        /// carries no `mac=`/`mc=` — the app then scans by name instead).
        public var mac: String?
    }

    /// Parses a pairing-QR payload byte-for-byte like the decompiled
    /// `startQRScan`: lowercase the whole string, extract after `btname=`,
    /// uppercase, strip the trailing `_<suffix>` (underscore-split, last
    /// segment dropped), restore `%20` → space. MAC from `mc=` or `mac=`;
    /// 12 hex digits → `AA:BB:…` pairs, 17 chars with colons kept as-is.
    public static func parsePairingQR(_ payload: String) -> PairingQR? {
        let lower = payload.lowercased()
        guard lower.contains("btname=") else { return nil }
        // Decompiled order: substring-after btname → uppercase → strip
        // trailing _suffix → %20 → space.
        let rawName = substring(after: "btname=", in: lower)
            .replacingOccurrences(of: "%20", with: " ")
            .uppercased()
        guard !rawName.isEmpty else { return nil }
        let baseName = rawName.split(separator: "_").dropLast().joined(separator: "_")
        let nameFilter = baseName
        var mac: String?
        for key in ["mc=", "mac="] where lower.contains(key) {
            let raw = substring(after: key, in: lower)
            guard !raw.isEmpty else { continue }
            let digits = raw.replacingOccurrences(of: ":", with: "")
            if raw.contains(":"), raw.count == 17 {
                mac = raw.uppercased()
            } else if digits.count >= 12 {
                let pairs = stride(from: 0, to: 12, by: 2).map { i -> String in
                    String(digits.dropFirst(i).prefix(2))
                }
                mac = pairs.joined(separator: ":").uppercased()
            }
            break
        }
        return PairingQR(deviceName: baseName, nameFilter: nameFilter, mac: mac)
    }

    /// First occurrence of `key`'s value, up to the next `&` or whitespace.
    private static func substring(after key: String, in s: String) -> String {
        guard let r = s.range(of: key) else { return "" }
        let rest = s[r.upperBound...]
        let end = rest.firstIndex(where: { $0 == "&" || $0 == " " || $0 == "\n" }) ?? rest.endIndex
        return String(rest[..<end])
    }

    // MARK: - Helpers

    static func leFloat(_ bytes: [UInt8], _ offset: Int) -> Float {
        guard offset + 4 <= bytes.count else { return 0 }
        var v: UInt32 = 0
        for i in (0..<4).reversed() { v = (v << 8) | UInt32(bytes[offset + i]) }
        return Float(bitPattern: v)
    }
}
