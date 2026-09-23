import Foundation
import CoreBluetooth
import ScaleKit

/// SRD-010 — boAt Storm Call 3 session (KaHa "Leonardo" protocol).
///
/// Pipeline: GATT connect → discover services → subscribe UART notify +
/// battery CCCD → queued handshake (name/firmware/time/battery/settings) →
/// live pushes stream. The protocol codec lives in ScaleKit (`KahaProtocol`).
///
/// Frame routing (decompiled ProtocolParser parity — fixes #34/#40/#41):
/// - **Responses** arrive with class = request class | 0x80: sport/history
///   acks on `0x81`, watch-face on `0x82`, device info on `0x80`.
/// - **Watch-initiated events** keep the plain class: controls `0x01 0x05`,
///   live data `0x06`.
/// - **Strict command queue** — the watch processes ONE command at a time
///   (`ProcessNextItemEvent` parity). Responses route by the in-flight
///   command (`commandObject.getCmdName()` parity): history stream headers
///   do NOT echo the request cmd, and unsolicited back-to-back requests are
///   refused.
final class WatchCentral: NSObject, ObservableObject {

    static let shared = WatchCentral()

    // MARK: - Published UI state

    enum Stage: Equatable {
        case idle
        case scanning
        case connecting
        case handshaking       // discovery + CCCDs + queued handshake
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
    /// True once the handshake commands have been queued (#31).
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

    // MARK: Command queue (decompiled ProcessNextItemEvent parity)

    /// What to do when the in-flight command's response arrives. Responses
    /// route by the in-flight command (decompiled `commandObject` parity) —
    /// history stream headers do NOT echo the request cmd.
    private enum AckKind {
        case none
        /// `0x7F` history stream → decoder by kind.
        case history(HistoryKind)
        /// Sport-mode start; carries the staged session (activated on ack=1).
        case sportStart(SportSession)
        /// Sport-mode end (mode-0 selection); any ack ends the session.
        case sportEnd
        /// Workout-day summary `81 23`; carries the daysAgo for the record id.
        case workoutSummary(day: Int)
    }
    private enum HistoryKind: Equatable {
        case hr(day: Int)
        case sleep(day: Int)
        case spo2(day: Int)
    }
    private struct QueuedCommand {
        let bytes: [UInt8]
        let label: String
        var ack: AckKind = .none
    }
    private var queue: [QueuedCommand] = []
    private var commandInFlight: QueuedCommand?
    private var ackTimer: DispatchWorkItem?
    /// Safety net for commands the watch never acks.
    private let ackTimeout: TimeInterval = 8
    /// One stop-then-start retry per start attempt (#41).
    private var sportRetryPending = false

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
        // No service filter (#38): the Realtek/KaHa watch does not advertise
        // the Nordic UART UUID — the official app scans by name only.
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
        // No service filter (#38) — scan by name only.
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
        // No service filter (#38) — scan by name only.
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        handshakeDone = false
        resetLink()
        stage = .idle
    }

    // MARK: - History (SRD-010 §5 acceptance 3, #34/#41)

    /// Requests one day of HR/BP history (day = 0 → today). The response
    /// streams back as `0x7F` multipackets routed by the in-flight command.
    func loadHRHistory(day: Int) {
        hrDay = day
        hrDated = []
        enqueue(KahaProtocol.setAutoHRInterval(minutes: 60), label: "auto-HR 60 min")
        enqueue(KahaProtocol.requestHRHistory(day: day, startHour: 0, endHour: 23),
                label: "HR history day \(day)", ack: .history(.hr(day: day)))
    }

    /// Requests one day of 10-min sleep + periodic SpO2 history, strictly
    /// serialized. Results persist into `WatchStore` (SRD-010 FR-2).
    func loadSleepAndSpo2History(day: Int) {
        sleepHours = []
        spo2Samples = []
        enqueue(KahaProtocol.requestSleepHistory(day: day, startHour: 0, endHour: 23),
                label: "sleep history day \(day)", ack: .history(.sleep(day: day)))
        enqueue(KahaProtocol.requestSpo2History(day: day, startHour: 0, endHour: 23),
                label: "SpO2 history day \(day)", ack: .history(.spo2(day: day)))
    }

    /// Pulls everything the official app shows for a day: HR/BP, sleep, SpO2
    /// (steps arrive as live pushes while connected).
    func loadDayHistory(day: Int) {
        loadHRHistory(day: day)
        loadSleepAndSpo2History(day: day)
    }

    // MARK: - Internals

    // MARK: Command queue plumbing

    /// Queues a command and starts it if the link is idle.
    private func enqueue(_ bytes: [UInt8], label: String, ack: AckKind = .none) {
        queue.append(QueuedCommand(bytes: bytes, label: label, ack: ack))
        drainQueue()
    }

    /// Sends the next command when nothing is in flight (strict lock-step).
    private func drainQueue() {
        guard commandInFlight == nil, !queue.isEmpty else { return }
        guard peripheral != nil else {
            queue.removeAll()
            return
        }
        let cmd = queue.removeFirst()
        commandInFlight = cmd
        appendLog("→ \(cmd.label)")
        send(cmd.bytes)
        let t = DispatchWorkItem { [weak self] in
            guard let self, let cur = self.commandInFlight,
                  cur.bytes == cmd.bytes else { return }
            self.appendLog("⏱ no ack for \(cmd.label) — continuing")
            self.completeInFlight()
        }
        ackTimer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + ackTimeout, execute: t)
    }

    /// Marks the in-flight command done and starts the next (decompiled
    /// `commandObject.setCompleted(true)` + `ProcessNextItemEvent`).
    private func completeInFlight() {
        ackTimer?.cancel()
        ackTimer = nil
        commandInFlight = nil
        drainQueue()
    }

    private func isResponseClass(_ c: UInt8) -> Bool {
        c == KahaProtocol.ClassId.responseInfo || c == KahaProtocol.ClassId.responseFitness
            || c == KahaProtocol.ClassId.responseAlerts
    }

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
        queue.removeAll()
        ackTimer?.cancel()
        ackTimer = nil
        commandInFlight = nil
        sportRetryPending = false
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
        // Handshake — every command goes through the queue; each 80-class
        // response completes its command in turn (#40: the previous
        // back-to-back burst had all but the first request dropped by the
        // watch, which is why firmware/battery/name never showed).
        enqueue(KahaProtocol.infoFrame(cmdId: KahaProtocol.InfoCmd.getDeviceName), label: "get name")
        enqueue(KahaProtocol.infoFrame(cmdId: KahaProtocol.InfoCmd.getFirmwareVersion), label: "get firmware")
        enqueue(KahaProtocol.infoFrame(cmdId: KahaProtocol.InfoCmd.getDeviceTime), label: "get time")
        enqueue(KahaProtocol.infoFrame(cmdId: KahaProtocol.InfoCmd.getBatteryLevel), label: "get battery")
        // 24-hour format + phone-type (Crest connect parity — the watch
        // treats 00 A6 05 00 00 as "phone paired, settings may flow").
        enqueue(KahaProtocol.frame(classId: KahaProtocol.ClassId.info,
                                   cmdId: KahaProtocol.InfoCmd.set24HourFormat,
                                   payload: [0x00]), label: "set 24h")
        enqueue(KahaProtocol.frame(classId: KahaProtocol.ClassId.info, cmdId: 0xA6, payload: [0x00]),
                label: "set phone type")
        // Resync the watch clock to the phone (#20).
        enqueue(KahaProtocol.setDeviceTime(from: Date()), label: "sync clock")
        handshakeDone = true
        stage = .live
        appendLog("watch live — handshake queued (7 commands)")
        pairedConfirmed = true
        // Watch-face inventory (#22) trails the handshake in the same queue.
        enqueue(KahaProtocol.requestWatchFaceList(), label: "watch-face list")
        enqueue(KahaProtocol.requestCurrentWatchFace(), label: "current watch face")
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
            return   // events never complete queued commands

        // --- Sport session acks (response class 0x81) ---
        case (KahaProtocol.ClassId.responseFitness, KahaProtocol.FitnessCmd.currentSportMode):
            handleSportModeAck(frame.payload)
        case (KahaProtocol.ClassId.responseFitness, KahaProtocol.FitnessCmd.activityPause):
            handlePauseAck(frame.payload)

        // --- Watch-face acks (response class 0x82) ---
        case (KahaProtocol.ClassId.responseAlerts, KahaProtocol.SystemCmd.watchFaceList):
            watchFaceIds = KahaProtocol.decodeWatchFaceList(frame.payload)
            appendLog("watch faces: \(watchFaceIds.map(String.init).joined(separator: ", "))")
        case (KahaProtocol.ClassId.responseAlerts, KahaProtocol.SystemCmd.watchFaceCurrent):
            currentWatchFaceId = KahaProtocol.decodeCurrentWatchFace(frame.payload)

        default:
            handleInfoResponse(frame)
        }
        // Response frames (and only those) release the queue lock.
        if isResponseClass(frame.classId) {
            completeInFlight()
        }
    }

    /// Sport-mode start/end acks, routed by the in-flight command (#41).
    private func handleSportModeAck(_ payload: [UInt8]) {
        let ok = KahaProtocol.decodeSportAck(payload) ?? false
        switch commandInFlight?.ack {
        case .sportStart(let pending):
            if ok {
                sportSession = pending
                sportRetryPending = false
                appendLog("watch started \(pending.mode) (\(pending.indoor ? "indoor" : "outdoor")) — end it on the watch or here")
            } else {
                appendLog("watch refused sport mode — raw ack: \(payload.hexString)")
                retrySportStart(pending)
            }
        case .sportEnd:
            // Mode-0 selection: the official app has no stop command, so both
            // ack values are treated as "session over".
            sportSession = nil
            sportRetryPending = false
            appendLog("sport session ended (ack \(payload.hexString)) — pulling summary")
            enqueue(KahaProtocol.requestWorkoutSummary(daysAgo: 0),
                    label: "workout summary today", ack: .workoutSummary(day: 0))
        default:
            appendLog("sport-mode ack while \(commandInFlight?.label ?? "idle"): \(payload.hexString)")
        }
    }

    /// Issue #41: the watch refuses a start when a session is already active
    /// (e.g. started on the watch itself). Stop first, then re-request once.
    private func retrySportStart(_ pending: SportSession) {
        guard !sportRetryPending else {
            appendLog("start failed again — end the watch-side session, then retry")
            return
        }
        sportRetryPending = true
        appendLog("stop-then-start retry scheduled")
        enqueue(KahaProtocol.stopSportMode(), label: "stop existing session")
        enqueue(KahaProtocol.startSportMode(pending.mode, indoor: pending.indoor),
                label: "re-start \(pending.mode)", ack: .sportStart(pending))
    }

    private func handlePauseAck(_ payload: [UInt8]) {
        let ok = KahaProtocol.decodeSportAck(payload) ?? false
        if var session = sportSession {
            session.paused = ok ? !session.paused : session.paused
            sportSession = session
            appendLog(ok ? (session.paused ? "session paused" : "session resumed")
                         : "pause/resume rejected — raw ack: \(payload.hexString)")
        } else {
            appendLog("pause/resume ack with no session: \(payload.hexString)")
        }
    }

    /// Info-class responses arrive with the `| 0x80` bit set (0x80 cmd echo).
    private func handleInfoResponse(_ frame: KahaProtocol.Frame) {
        guard frame.classId == KahaProtocol.ClassId.responseInfo else { return }
        switch frame.cmdId {
        case KahaProtocol.InfoCmd.getDeviceName:
            deviceName = frame.payload.asciiString
        case KahaProtocol.InfoCmd.getFirmwareVersion:
            // Issue #40: version payloads may carry a length/binary prefix —
            // fall back to the printable subset, then hex, so the field is
            // never silently blank.
            if let s = frame.payload.asciiString {
                firmwareVersion = s
            } else {
                let printable = frame.payload.filter { (0x20..<0x7F).contains($0) }
                firmwareVersion = printable.isEmpty
                    ? frame.payload.hexString
                    : String(bytes: printable, encoding: .ascii)
                appendLog("firmware raw payload: \(frame.payload.hexString)")
            }
        case KahaProtocol.InfoCmd.getDeviceTime:
            watchTime = KahaProtocol.decodeDeviceTime(frame.payload)
        case KahaProtocol.InfoCmd.getBatteryLevel:
            batteryPercent = KahaProtocol.decodeBattery(frame.payload)
        default:
            break
        }
    }

    /// `81 23` workout-day payload: steps u32 LE, meters f32, kcal f32
    /// (mirrors TodaysFitnessDataRes / LiveStepsRes field order).
    private func decodeWorkoutSummary(_ p: [UInt8], day: Int) -> WorkoutDay? {
        guard p.count >= 12 else { return nil }
        let steps = Int(p[0]) | (Int(p[1]) << 8) | (Int(p[2]) << 16) | (Int(p[3]) << 24)
        return WorkoutDay(id: day, steps: steps,
                          calories: Double(KahaProtocol.leFloat(p, 8)),
                          distanceMeters: Double(KahaProtocol.leFloat(p, 4)))
    }

    /// Reacts to watch-initiated control pushes (#25/#26/#30/#35/#36).
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
        enqueue(KahaProtocol.setAlertSwitches(apps), label: "alert switches")
    }

    func sendIncomingCall(caller: String) {
        sendNotification(title: "", body: caller, type: 1)
    }

    func musicPlayback(playing: Bool) {
        enqueue(KahaProtocol.setMusicPlayback(playing: playing),
                label: playing ? "music play" : "music pause")
    }

    func musicVolume(_ percent: Int) {
        enqueue(KahaProtocol.setMusicVolume(percent: percent), label: "music volume")
    }

    /// Phone→watch camera-status command (#25): tells the watch the phone
    /// camera session is active so its remote-shutter button works.
    func cameraRemote(enter: Bool) {
        enqueue(KahaProtocol.setCameraRemote(enter: enter),
                label: enter ? "camera remote enter" : "camera remote exit")
    }

    func findMyWatch(start: Bool) {
        enqueue(KahaProtocol.findMyWatch(start: start),
                label: start ? "ring watch" : "stop ringing watch")
    }

    func switchWatchFace(_ id: Int) {
        enqueue(KahaProtocol.setWatchFace(id: id), label: "watch face → \(id)")
    }

    func loadWorkoutDays(_ days: [Int]) {
        for d in days {
            enqueue(KahaProtocol.requestWorkoutSummary(daysAgo: d),
                    label: "workout summary day -\(d)", ack: .workoutSummary(day: d))
        }
    }

    // MARK: - Sport session control (SRD-010 §9)

    /// Start a workout on the watch (running/walking/cycling/swimming/taichi).
    /// Watch acks `81 8B` with payload[0]=1, then shows its sport screen.
    func startWorkout(_ mode: KahaProtocol.SportMode, indoor: Bool = false) {
        guard sportSession == nil else {
            appendLog("a session is already running — end it first")
            return
        }
        let pending = SportSession(mode: mode, indoor: indoor, startedAt: Date())
        enqueue(KahaProtocol.startSportMode(mode, indoor: indoor),
                label: "start \(mode) workout", ack: .sportStart(pending))
    }

    /// Phone-side stop: re-select mode 0. The official app has no stop
    /// command — the watch may also end the session from its own screen.
    func endWorkout() {
        guard sportSession != nil else { return }
        enqueue(KahaProtocol.stopSportMode(), label: "end workout", ack: .sportEnd)
    }

    func pauseWorkout() {
        guard sportSession?.paused == false else { return }
        enqueue(KahaProtocol.pauseSportSession(), label: "pause workout")
    }

    func resumeWorkout() {
        guard sportSession?.paused == true else { return }
        enqueue(KahaProtocol.resumeSportSession(), label: "resume workout")
    }

    // MARK: - History data dispatch (multipacket complete, #34/#41)

    /// Routes an assembled stream by the IN-FLIGHT command's decoder kind —
    /// the stream header does not echo the request cmd (verified live: the
    /// watch sends cmd 0x04 stream headers for HR history requests).
    private func deliverHistoryData(cmd: UInt8, data: [UInt8]) {
        switch commandInFlight?.ack {
        case .history(.hr(let day)):
            hrDay = day
            hrDated = KahaProtocol.decodeHRHistory(data, intervalMinutes: 60,
                                                   startHour: 0, day: day)
            persistHRDay()
            appendLog("HR history: \(hrDated.count) samples (stream cmd 0x\(String(cmd, radix: 16)))")
            completeInFlight()
        case .history(.sleep(let day)):
            hrDay = day
            sleepHours = KahaProtocol.decodeSleepHistory(data, startHour: 0)
            persistSleepDay()
            let total = sleepHours.reduce(0.0) { $0 + $1.totalSleepMinutes }
            appendLog("sleep history: \(sleepHours.count) hours · \(String(format: "%.0f", total)) min sleep")
            completeInFlight()
        case .history(.spo2(let day)):
            hrDay = day
            spo2Samples = KahaProtocol.decodeSpo2History(data, startHour: 0, day: day)
            persistSpo2Day()
            if let avg = spo2Average {
                appendLog("SpO2 history: \(spo2Samples.count) samples · avg \(avg)%")
            } else {
                appendLog("SpO2 history: no valid samples")
            }
            completeInFlight()
        case .workoutSummary(let day):
            if let d = decodeWorkoutSummary(data, day: day) {
                if let i = workoutDays.firstIndex(where: { $0.id == d.id }) {
                    workoutDays[i] = d
                } else {
                    workoutDays.insert(d, at: 0)
                }
                appendLog("workout day -\(d.id): \(d.steps) steps · \(Int(d.distanceMeters)) m · \(Int(d.calories)) kcal")
            }
            completeInFlight()
        default:
            appendLog("history stream cmd 0x\(String(cmd, radix: 16)) (\(data.count) bytes) — no in-flight decoder")
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
        queue.removeAll()
        commandInFlight = nil
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
        // Both CCCDs up (and no pending standard reads) → queued handshake.
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
        // `0x7F` multipackets are reassembled and routed by the in-flight
        // command (#34/#41). Everything else parses as a plain frame.
        if raw.first == KahaProtocol.ClassId.multipacket {
            for (cmd, data) in assembler.feed(raw) {
                deliverHistoryData(cmd: cmd, data: data)
            }
        } else if let frame = KahaProtocol.parse(raw) {
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
