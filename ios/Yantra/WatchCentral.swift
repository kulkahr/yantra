import Foundation
import CoreBluetooth
import ScaleKit

/// SRD-010 — boAt Storm Call 3 session (KaHa "Leonardo" protocol).
///
/// Pipeline: GATT connect → discover services → subscribe UART notify +
/// battery CCCD → info request burst (name/firmware/time/battery + clock
/// resync) → live pushes stream. The protocol codec lives in ScaleKit
/// (`KahaProtocol`); this class owns transport + published UI state,
/// mirroring `ScaleCentral`.
///
/// Frame routing (decompiled ProtocolParser parity — fixes #34 and the
/// start-workout no-op):
/// - **Responses** arrive with class = request class | 0x80: sport/history
///   acks on `0x81`, watch-face on `0x82`, device info on `0x80`.
/// - **Watch-initiated events** keep the plain class: controls `0x01 0x05`,
///   live data `0x06`.
/// - **History** (HR/sleep/SpO2) streams as `0x7F` multipackets reassembled
///   by `MultipacketAssembler`; the stream's cmd byte routes the decoder.
final class WatchCentral: NSObject, ObservableObject {

    static let shared = WatchCentral()

    // MARK: - Published UI state

    enum Stage: Equatable {
        case idle
        case scanning
        case connecting
        case handshaking       // discovery + CCCDs + info requests
        case live              // connected, live data flowing
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var log: [String] = []
    @Published private(set) var deviceName: String?
    @Published private(set) var firmwareVersion: String?
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var watchTime: Date?
    @Published private(set) var liveHealth: KahaProtocol.LiveHealth?
    @Published private(set) var liveSteps: KahaProtocol.LiveSteps?
    @Published private(set) var hrDay: Int = 0
    @Published private(set) var sleepHours: [KahaProtocol.SleepHour] = []
    @Published private(set) var spo2Samples: [KahaProtocol.SpO2Sample] = []
    /// HR history with sample timestamps (drives the UI timeline + persistence).
    @Published private(set) var hrDated: [(date: Date, sample: KahaProtocol.HRSample)] = []
    /// UI-facing samples (compat view of `hrDated`).
    var hrSamples: [KahaProtocol.HRSample] { hrDated.map { $0.sample } }
    /// Watch-face ids on the device + currently active one (#22).
    @Published private(set) var watchFaceIds: [Int] = []
    @Published private(set) var currentWatchFaceId: Int?
    /// Watch-side control events for the UI to react to (#25/#26/#30).
    @Published private(set) var lastWatchEvent: KahaProtocol.WatchControlEvent?
    /// True once the watch ACKed our settings burst after the handshake (#31).
    @Published private(set) var pairedConfirmed = false
    /// Latest workout summary days pulled (#28), most recent first.
    @Published private(set) var workoutDays: [WorkoutDay] = []

    struct WorkoutDay: Identifiable, Equatable {
        let id: Int            // daysAgo
        let steps: Int
        let calories: Double
        let distanceMeters: Double
    }

    /// Live sport session started from the phone (SRD-010 §9).
    struct SportSession: Equatable {
        let mode: KahaProtocol.SportMode
        let indoor: Bool
        let startedAt: Date
        var paused: Bool = false
    }
    /// Non-nil while a phone-started workout is running on the watch.
    @Published private(set) var sportSession: SportSession?
    /// Staged start request awaiting the `81 8B` ack.
    private var pendingSportStart: SportSession?

    @Published private(set) var foundWatches: [DiscoveredWatch] = []

    struct DiscoveredWatch: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    // MARK: - Link state

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var subscribed: Set<CBUUID> = []
    private var handshakeDone = false
    private var firmwareReadPending = false
    private var scanTimeout: DispatchWorkItem?
    /// QR-pairing targets: MAC from the QR (logged only — iOS addresses by
    /// peripheral UUID) and the decoded name filter used to match advertisements.
    private var connectTargetMAC: String?
    private var connectTargetName: String?
    private var pendingPair: UUID?

    /// `0x7F` multipacket reassembly (history streams).
    private let assembler = MultipacketAssembler()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var bluetoothOn: Bool { central.state == .poweredOn }

    // MARK: - Scanning / pairing

    func startScan() {
        foundWatches = []
        stage = .scanning
        guard central.state == .poweredOn else { return }
        scheduleScanTimeout()
        // Nordic UART service filter — Storm Call 3 exposes it.
        // No service filter (#38): the Realtek/KaHa watch does not advertise the
        // Nordic UART UUID — the official app scans by name only.
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func stopScan() {
        scanTimeout?.cancel()
        scanTimeout = nil
        central.stopScan()
        if stage == .scanning { stage = .idle }
    }

    private func scheduleScanTimeout() {
        scanTimeout?.cancel()
        let t = DispatchWorkItem { [weak self] in
            guard let self, self.stage == .scanning else { return }
            self.central.stopScan()
            self.stage = .idle
            self.appendLog("scan timed out (30 s)")
        }
        scanTimeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: t)
    }

    /// Pair: connect + handshake. The hub persists the inventory row
    /// (DeviceStore) — this only manages the link.
    func pair(_ watch: DiscoveredWatch) {
        pendingPair = watch.id
        registerInInventory(peripheralId: watch.id, name: watch.name)
        resetLink()
        if let p = central.retrievePeripherals(withIdentifiers: [watch.id]).first {
            peripheral = p
            p.delegate = self
            central.connect(p)
            stage = .connecting
        } else {
            // Issue #37: not in the system cache (stale row / rebooted phone) —
            // rescan and auto-connect on the first matching advertisement
            // instead of dead-ending in "out of range".
            appendLog("watch not cached — rescanning to reconnect")
            scanAndPair(nameFilter: watch.name)
        }
    }

    // MARK: QR pairing (official-app parity, SRD-010 §3)

    /// Pairs straight from a scanned QR payload (`btname=…&mac=…`). With a MAC
    /// the watch is addressed directly (decompiled `getRemoteDevice` parity);
    /// without one we scan for the name filter and pair the first hit
    /// (`ScanDeviceRequest` scanFilter parity).
    func pair(fromQR qr: KahaProtocol.PairingQR) {
        if let mac = qr.mac {
            appendLog("QR: \(qr.nameFilter) @ \(mac)")
            connect(mac: mac, name: qr.nameFilter)
        } else {
            appendLog("QR: no MAC — scanning for \(qr.nameFilter)")
            scanAndPair(nameFilter: qr.nameFilter)
        }
    }

    /// Direct connect by MAC — mirrors the official app's
    /// `BluetoothAdapter.getRemoteDevice(mac)` + connect path.
    func connect(mac: String, name: String) {
        // iOS has no MAC-level addressing; the hub re-identifies the peripheral
        // by scanning briefly and matching the advertised name filter — the
        // discovery callback records `peripheralId` for later direct reconnects.
        connectTargetMAC = mac.uppercased()
        connectTargetName = name.uppercased()
        resetLink()
        foundWatches = []
        stage = .scanning
        guard central.state == .poweredOn else { return }
        scheduleScanTimeout()
        // No service filter (#38): the Realtek/KaHa watch does not advertise the
        // Nordic UART UUID — the official app scans by name only.
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    /// Name-filter scan → pair first matching advertisement. `nil` filter
    /// pairs the first STORMCALL advertisement (issue #37 retry path).
    private func scanAndPair(nameFilter: String?) {
        connectTargetMAC = nil
        connectTargetName = nameFilter?.uppercased()
        resetLink()
        foundWatches = []
        stage = .scanning
        guard central.state == .poweredOn else { return }
        scheduleScanTimeout()
        // No service filter (#38): the Realtek/KaHa watch does not advertise the
        // Nordic UART UUID — the official app scans by name only.
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        handshakeDone = false
        assembler.reset()
        stage = .idle
    }

    // MARK: - History (SRD-010 §5 acceptance 3, #34)

    /// Requests one day of HR/BP history (day = 0 → today). The response
    /// streams back as `0x7F` multipackets; the assembler feeds the decoder.
    func loadHRHistory(day: Int) {
        hrDay = day
        hrDated = []
        send(KahaProtocol.setAutoHRInterval(minutes: 60))
        send(KahaProtocol.requestHRHistory(day: day, startHour: 0, endHour: 23))
        appendLog("HR history requested (day \(day))")
    }

    /// Requests one day of 10-min sleep + periodic SpO2 history. Decoded
    /// results persist into `WatchStore` (SRD-010 FR-2) and update published
    /// state for the UI.
    func loadSleepAndSpo2History(day: Int) {
        sleepHours = []
        spo2Samples = []
        send(KahaProtocol.requestSleepHistory(day: day, startHour: 0, endHour: 23))
        send(KahaProtocol.requestSpo2History(day: day, startHour: 0, endHour: 23))
        appendLog("sleep/SpO2 history requested (day \(day))")
    }

    /// Pulls everything the official app shows for a day: HR/BP, sleep, SpO2
    /// (steps arrive as live pushes while connected).
    func loadDayHistory(day: Int) {
        loadHRHistory(day: day)
        loadSleepAndSpo2History(day: day)
    }

    // MARK: - Internals

    /// Issue #38: QR/scanner pairing must land in the persistent inventory,
    /// otherwise the hub shows nothing and a restart drops the watch entirely.
    /// Idempotent — also refreshes the stored name.
    private func registerInInventory(peripheralId: UUID, name: String) {
        Task { @MainActor in
            DeviceStore.shared.upsert(PairedDevice(peripheralId: peripheralId,
                                                   kind: .watch, name: name,
                                                   addedAt: Date()))
        }
    }

    /// ScaleKit UUIDs are pure Foundation; CoreBluetooth wants CBUUID.
    private func cb(_ u: UUID) -> CBUUID { CBUUID(string: u.uuidString) }

    private func resetLink() {
        chars = [:]
        subscribed = []
        firmwareReadPending = false
        handshakeDone = false
        assembler.reset()
    }

    private func send(_ bytes: [UInt8]) {
        guard let p = peripheral, let c = chars[cb(KahaProtocol.GATT.uartWrite)] else {
            appendLog("✗ write dropped — UART not ready (\(Array(bytes.prefix(2)).hexString))")
            return
        }
        p.writeValue(Data(bytes), for: c, type: .withResponse)
    }

    private func subscribe(_ c: CBCharacteristic) {
        guard !subscribed.contains(c.uuid) else { return }
        subscribed.insert(c.uuid)
        peripheral?.setNotifyValue(true, for: c)
    }

    private func requestInfo() {
        // Info request burst — responses arrive as 80-class frames.
        send(KahaProtocol.infoFrame(cmdId: KahaProtocol.InfoCmd.getDeviceName))
        send(KahaProtocol.infoFrame(cmdId: KahaProtocol.InfoCmd.getFirmwareVersion))
        send(KahaProtocol.infoFrame(cmdId: KahaProtocol.InfoCmd.getDeviceTime))
        send(KahaProtocol.infoFrame(cmdId: KahaProtocol.InfoCmd.getBatteryLevel))
        // 24-hour format + phone-type (Crest connect parity — the watch
        // treats 00 A6 05 00 00 as "phone paired, settings may flow").
        send(KahaProtocol.frame(classId: KahaProtocol.ClassId.info,
                                cmdId: KahaProtocol.InfoCmd.set24HourFormat,
                                payload: [0x00]))
        send(KahaProtocol.frame(classId: KahaProtocol.ClassId.info, cmdId: 0xA6, payload: [0x00]))
        // Resync the watch clock to the phone (#20).
        send(KahaProtocol.setDeviceTime(from: Date()))
        handshakeDone = true
        pairedConfirmed = true
        stage = .live
        appendLog("watch live — paired & synced")
        // Kick off the watch-face inventory (#22).
        send(KahaProtocol.requestWatchFaceList())
        send(KahaProtocol.requestCurrentWatchFace())
    }

    // MARK: - Frame handling

    /// One parsed notification dispatched by class/cmd per the ProtocolParser
    /// map. Response classes carry the `| 0x80` bit; events keep the plain class.
    private func handleFrame(_ frame: KahaProtocol.Frame) {
        switch (frame.classId, frame.cmdId) {

        // --- Live pushes (watch-initiated, plain class 0x06) ---
        case (KahaProtocol.ClassId.live, KahaProtocol.LiveCmd.liveHealth):
            if let h = KahaProtocol.decodeLiveHealth(frame.payload) {
                liveHealth = h
                appendLog("live HR \(h.heartRate) bpm · BP \(h.systolic)/\(h.diastolic) · stress \(h.stress)")
            }
        case (KahaProtocol.ClassId.live, KahaProtocol.LiveCmd.liveSteps):
            if let s = KahaProtocol.decodeLiveSteps(frame.payload) {
                liveSteps = s
                persistLiveSteps()
                appendLog("live steps \(s.steps)")
            }

        // --- Watch-initiated control events (plain class 0x01, cmd 0x05) ---
        case (KahaProtocol.ClassId.fitness, 0x05):
            if let event = KahaProtocol.decodeWatchControl(frame) {
                lastWatchEvent = event
                handleWatchEvent(event)
            }

        // --- Latest-health one-shot (response 80 0A) ---
        case (KahaProtocol.ClassId.responseInfo, KahaProtocol.FitnessCmd.latestHealth):
            if let lh = KahaProtocol.decodeLatestHealth(frame.payload) {
                appendLog("latest health: value \(lh.value) @ \(Date(timeIntervalSince1970: TimeInterval(lh.secondsSinceEpoch)))")
            }

        // --- Sport session acks (response class 0x81) ---
        case (KahaProtocol.ClassId.responseFitness, KahaProtocol.FitnessCmd.currentSportMode):
            if let ok = KahaProtocol.decodeSportAck(frame.payload) {
                if ok, let pending = pendingSportStart {
                    sportSession = pending
                    appendLog("watch started \(pending.mode) (\(pending.indoor ? "indoor" : "outdoor")) — end it on the watch")
                } else if !ok, sportSession != nil, pendingSportStart == nil {
                    sportSession = nil
                    appendLog("sport session ended")
                    // Pull today's summary so the workout shows up in Workouts (#28).
                    loadWorkoutDays([0])
                } else if !ok {
                    appendLog("watch refused sport mode (already active or unsupported)")
                }
                pendingSportStart = nil
            }
        case (KahaProtocol.ClassId.responseFitness, KahaProtocol.FitnessCmd.activityPause):
            if let ok = KahaProtocol.decodeSportAck(frame.payload), var session = sportSession {
                session.paused = ok ? !session.paused : session.paused
                appendLog(ok ? (session.paused ? "session paused" : "session resumed") : "pause/resume rejected")
                sportSession = session
            }

        // --- Watch-face acks (response class 0x82) ---
        case (KahaProtocol.ClassId.responseAlerts, KahaProtocol.SystemCmd.watchFaceList):
            watchFaceIds = KahaProtocol.decodeWatchFaceList(frame.payload)
            appendLog("watch faces: \(watchFaceIds.map(String.init).joined(separator: ", "))")
        case (KahaProtocol.ClassId.responseAlerts, KahaProtocol.SystemCmd.watchFaceCurrent):
            currentWatchFaceId = KahaProtocol.decodeCurrentWatchFace(frame.payload)

        default:
            handleInfoResponse(frame)
        }
    }

    /// Info-class responses arrive with the `| 0x80` bit set (0x80 cmd echo).
    private func handleInfoResponse(_ frame: KahaProtocol.Frame) {
        guard frame.classId == KahaProtocol.ClassId.responseInfo else { return }
        // Response cmd = request cmd (echo) — decode by the plain request id.
        switch frame.cmdId {
        case KahaProtocol.InfoCmd.getDeviceName:
            deviceName = frame.payload.asciiString
        case KahaProtocol.InfoCmd.getFirmwareVersion:
            firmwareVersion = frame.payload.asciiString
        case KahaProtocol.InfoCmd.getDeviceTime:
            watchTime = KahaProtocol.decodeDeviceTime(frame.payload)
        case KahaProtocol.InfoCmd.getBatteryLevel:
            batteryPercent = KahaProtocol.decodeBattery(frame.payload)
        default:
            break
        }
    }

    /// `01 23` workout-day payload: steps u32 LE, meters f32, kcal f32
    /// (mirrors TodaysFitnessDataRes / LiveStepsRes field order).
    private func decodeWorkoutSummary(_ p: [UInt8]) -> WorkoutDay? {
        guard p.count >= 12 else { return nil }
        let steps = Int(p[0]) | (Int(p[1]) << 8) | (Int(p[2]) << 16) | (Int(p[3]) << 24)
        return WorkoutDay(id: hrDay, steps: steps,
                          calories: Double(KahaProtocol.leFloat(p, 8)),
                          distanceMeters: Double(KahaProtocol.leFloat(p, 4)))
    }

    /// Reacts to watch-initiated control pushes (#25/#26/#30/#35/#36).
    /// Coordinator hops run on the main actor — handleWatchEvent executes in a
    /// synchronous nonisolated context (CBPeripheralDelegate path).
    private func handleWatchEvent(_ event: KahaProtocol.WatchControlEvent) {
        switch event {
        case .findMyPhone:
            // #35: ring + vibrate the phone, not just a notification.
            Task { @MainActor in
                FindPhoneCoordinator.shared.begin()
            }
            appendLog("watch asks: find my phone — ringing & vibrating")
        case .cameraEnter:
            appendLog("watch: camera remote")
        case .cameraCapture:
            // #36: take a real photo from the watch shutter.
            Task { @MainActor in
                WatchCameraCoordinator.shared.captureFromWatch()
            }
            appendLog("watch: shutter — capturing photo")
        case .callReject, .callMute:
            let action = (event == .callReject) ? "reject" : "mute"
            appendLog("watch: call \(action)")
        case .musicPlay, .musicPause, .musicNext, .musicPrevious,
             .volumeUp, .volumeDown:
            appendLog("watch music: \(event)")
        }
    }

    // MARK: - Phone → watch controls (#23/#24/#25/#26/#30)

    func sendNotification(title: String, body: String, type: UInt8 = 18) {
        let text = title.isEmpty ? body : "\(title): \(body)"
        for f in KahaProtocol.sendMessage(String(text.prefix(58)), type: type) {
            send(f)
        }
    }

    func setNotificationApps(_ apps: KahaProtocol.AlertApps) {
        send(KahaProtocol.setAlertSwitches(apps))
        appendLog("alert switches → 0x\(String(apps.rawValue, radix: 16))")
    }

    func sendIncomingCall(caller: String) {
        sendNotification(title: "", body: caller, type: 1)
    }

    func musicPlayback(playing: Bool) {
        send(KahaProtocol.setMusicPlayback(playing: playing))
    }

    func musicVolume(_ percent: Int) {
        send(KahaProtocol.setMusicVolume(percent: percent))
    }

    /// Phone→watch camera-status command (#25): tells the watch the phone
    /// camera session is active so its remote-shutter button works.
    func cameraRemote(enter: Bool) {
        send(KahaProtocol.setCameraRemote(enter: enter))
        appendLog("camera remote \(enter ? "entered" : "left")")
    }

    func findMyWatch(start: Bool) {
        send(KahaProtocol.findMyWatch(start: start))
    }

    func switchWatchFace(_ id: Int) {
        send(KahaProtocol.setWatchFace(id: id))
        appendLog("watch face → \(id)")
    }

    func loadWorkoutDays(_ days: [Int]) {
        for d in days {
            send(KahaProtocol.requestWorkoutSummary(daysAgo: d))
        }
        appendLog("workout summaries requested: \(days)")
    }

    // MARK: - Sport session control (SRD-010 §9)

    /// Start a workout on the watch (running/walking/cycling/swimming/taichi).
    /// Watch acks `81 8B` with payload[0]=1, then shows its sport screen.
    func startWorkout(_ mode: KahaProtocol.SportMode, indoor: Bool = false) {
        guard sportSession == nil else {
            appendLog("a session is already running — end it first")
            return
        }
        pendingSportStart = SportSession(mode: mode, indoor: indoor, startedAt: Date())
        send(KahaProtocol.startSportMode(mode, indoor: indoor))
        appendLog("starting \(mode) workout…")
    }

    /// Phone-side stop: re-select mode 0; the watch acks with 0 and we
    /// clear the session, then pull today's summary.
    func endWorkout() {
        guard sportSession != nil else { return }
        pendingSportStart = nil
        send(KahaProtocol.stopSportMode())
        appendLog("ending workout…")
    }

    func pauseWorkout() {
        guard sportSession?.paused == false else { return }
        send(KahaProtocol.pauseSportSession())
    }

    func resumeWorkout() {
        guard sportSession?.paused == true else { return }
        send(KahaProtocol.resumeSportSession())
    }

    // MARK: - History data dispatch (multipacket complete, #34)

    /// Routes an assembled history stream by its cmd byte, then persists.
    private func deliverHistoryData(cmd: UInt8, data: [UInt8]) {
        switch cmd {
        case KahaProtocol.FitnessCmd.hrBpInterval:
            hrDated = KahaProtocol.decodeHRHistory(data, intervalMinutes: 60,
                                                   startHour: 0, day: hrDay)
            persistHRDay()
            appendLog("HR history: \(hrDated.count) samples")
        case KahaProtocol.FitnessCmd.sleepHistory:
            sleepHours = KahaProtocol.decodeSleepHistory(data, startHour: 0)
            persistSleepDay()
            let total = sleepHours.reduce(0.0) { $0 + $1.totalSleepMinutes }
            appendLog("sleep history: \(sleepHours.count) hours · \(String(format: "%.0f", total)) min sleep")
        case KahaProtocol.FitnessCmd.spo2History:
            spo2Samples = KahaProtocol.decodeSpo2History(data, startHour: 0, day: hrDay)
            persistSpo2Day()
            if let avg = spo2Average {
                appendLog("SpO2 history: \(spo2Samples.count) samples · avg \(avg)%")
            } else {
                appendLog("SpO2 history: no valid samples")
            }
        default:
            appendLog("history stream cmd 0x\(String(cmd, radix: 16)) (\(data.count) bytes) — no decoder")
        }
    }

    var spo2Average: Int? {
        guard !spo2Samples.isEmpty else { return nil }
        return spo2Samples.map { $0.percent }.reduce(0, +) / spo2Samples.count
    }

    // MARK: - Persistence (WatchStore, SRD-010 FR-2)

    /// Persistence helpers hop to the main actor — `handleFrame` runs from the
    /// nonisolated CBPeripheralDelegate conformance.
    private func persistHRDay() {
        let byHour: [Int: Int] = Dictionary(hrDated.compactMap { entry in
            entry.sample.heartRate > 0
                ? (Calendar.current.component(.hour, from: entry.date), entry.sample.heartRate)
                : nil
        }, uniquingKeysWith: { _, new in new })
        guard !byHour.isEmpty else { return }
        let key = WatchStore.dayKey(for: Date().addingTimeInterval(Double(-hrDay) * 86_400))
        Task { @MainActor in
            WatchStore.shared.upsert(day: key, hrByHour: byHour)
        }
    }

    private func persistSleepDay() {
        guard !sleepHours.isEmpty else { return }
        let key = WatchStore.dayKey(for: Date().addingTimeInterval(Double(-hrDay) * 86_400))
        let hours = sleepHours
        Task { @MainActor in
            for h in hours {
                WatchStore.shared.upsert(day: key, sleep: h)
            }
        }
    }

    private func persistSpo2Day() {
        guard !spo2Samples.isEmpty else { return }
        let key = WatchStore.dayKey(for: Date().addingTimeInterval(Double(-hrDay) * 86_400))
        let samples = spo2Samples
        Task { @MainActor in
            WatchStore.shared.upsert(day: key, spo2: samples)
        }
    }

    private func persistLiveSteps() {
        guard let s = liveSteps else { return }
        let key = WatchStore.dayKey(for: Date())
        Task { @MainActor in
            WatchStore.shared.upsert(day: key, steps: s.steps,
                                     calories: s.calories, distanceMeters: s.meters)
        }
    }

    private func appendLog(_ s: String) {
        log.append(s)
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }
}

// MARK: - CBCentralManagerDelegate

extension WatchCentral: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn, stage == .scanning else { return }
        // No service filter (#38): the Realtek/KaHa watch does not advertise the
        // Nordic UART UUID — the official app scans by name only.
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard stage == .scanning else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        guard let n = name else { return }
        let upper = n.uppercased()
        // QR-pairing scan: match the decoded name filter (official-app parity:
        // name starts with the filter, e.g. STORMCALL…). Normal scan: any
        // stormcall device.
        if let filter = connectTargetName {
            // Prefix match either way, or a shared STORMCALL family match —
            // covers retries where the stored name is generic ("Storm Call 3").
            guard upper.hasPrefix(filter) || filter.hasPrefix(upper)
                  || (upper.contains("STORMCALL") && filter.contains("STORMCALL"))
            else { return }
        } else if !upper.contains("STORMCALL") {
            return
        }
        let entry = DiscoveredWatch(id: peripheral.identifier, name: n, rssi: RSSI.intValue)
        if !foundWatches.contains(entry) { foundWatches.append(entry) }
        // Auto-pair on first hit when pairing was initiated by QR/MAC or by a
        // cache-miss retry (issue #37).
        if connectTargetName != nil || pendingPair != nil {
            stopScan()
            pendingPair = peripheral.identifier
            resetLink()
            peripheral.delegate = self
            central.connect(peripheral)
            registerInInventory(peripheralId: peripheral.identifier, name: n)
            stage = .connecting
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        appendLog("GATT connected — discovering services")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        stage = .failed("connect failed: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handshakeDone = false
        stage = .failed(error == nil ? "watch disconnected" : "disconnected: \(error!.localizedDescription)")
    }
}

// MARK: - CBPeripheralDelegate

extension WatchCentral: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        for c in service.characteristics ?? [] {
            chars[c.uuid] = c
            if c.uuid == cb(KahaProtocol.GATT.uartRead) || c.uuid == cb(KahaProtocol.GATT.batteryLevel) {
                subscribe(c)
            }
            if c.uuid == cb(KahaProtocol.GATT.firmwareRevision), !firmwareReadPending {
                firmwareReadPending = true
                peripheral.readValue(for: c)
            }
        }
        // Both CCCDs up (and no pending standard reads) → info request burst.
        if subscribed.contains(cb(KahaProtocol.GATT.uartRead)),
           subscribed.contains(cb(KahaProtocol.GATT.batteryLevel)),
           !handshakeDone, !firmwareReadPending {
            requestInfo()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let v = characteristic.value else { return }
        // Reads AND notifications both land here (issue #8 lesson).
        if !characteristic.isNotifying {
            if characteristic.uuid == cb(KahaProtocol.GATT.firmwareRevision), firmwareReadPending {
                firmwareVersion = String(data: v, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                firmwareReadPending = false
                requestInfo()
            }
            return
        }
        guard characteristic.uuid == cb(KahaProtocol.GATT.uartRead) else {
            if characteristic.uuid == cb(KahaProtocol.GATT.batteryLevel) {
                batteryPercent = KahaProtocol.decodeBattery([UInt8](v))
            }
            return
        }
        let raw = [UInt8](v)
        // `0x7F` multipackets are reassembled; complete streams dispatch by the
        // stream's cmd byte (#34). Everything else parses as a plain frame.
        for (cmd, data) in assembler.feed(raw) {
            deliverHistoryData(cmd: cmd, data: data)
        }
        if raw.first != KahaProtocol.ClassId.multipacket,
           let frame = KahaProtocol.parse(raw) {
            handleFrame(frame)
        }
    }
}

// MARK: - Small helpers

private extension Array where Element == UInt8 {
    var asciiString: String? {
        let d = Data(self)
        guard let s = String(data: d, encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }
    var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}
