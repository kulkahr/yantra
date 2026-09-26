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
    @Published private(set) var hardwareVersion: String?
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
    /// #49: the watch refused an app-started sport session. The Storm Call 3
    /// firmware does not accept `01 8B` from the phone (the official app marks
    /// it `sportModeSupportedFromApp = false` and never offers the feature),
    /// so the UI hides the start-workout controls after the first refusal.
    @Published private(set) var sportStartUnsupported = false

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
    /// QF10 (audit #8): was a battery characteristic ever discovered? Gates
    /// the handshake — firmware without 0x2A19 must not block going live.
    private var sawBatteryChar = false
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
    private enum AckKind: Equatable {
        case none
        /// `0x7F` history stream → decoder by kind.
        case history(HistoryKind)
        /// Sport-mode start; carries the staged session (activated on ack=1).
        case sportStart(SportSession)
        /// Sport-mode end (mode-0 selection); any ack ends the session.
        case sportEnd
        /// Workout-day summary `81 23`; carries the daysAgo for the record id.
        case workoutSummary(day: Int)
        /// Today's steps/fitness `01 00`/`01 2f` (GET_WALK_VALUE /
        /// GET_TODAY_FITNESS) — also matches the stream header cmd 0x0D the
        /// watch uses for this class of history replies.
        case steps
        /// `80 A8` phone-book set ack (#50).
        case phoneBook
        /// `82 8F` watch-face switch ack (#46); carries the requested id so the
        /// UI updates only after the watch confirms.
        case watchFaceSet(id: Int)
        /// `80 B4` navigation-status ack (#60).
        case navigationStatus
        /// `82 8A` navigation-event ack (#60).
        case navigationEvent
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
    /// QF14 (audit #25): ONE automatic reconnect retry after an unexpected
    /// disconnect or failed connect — 6 s out, cancelled by any user flow
    /// (disconnect/scan/pair), flag reset when the link comes back up.
    private var reconnectWork: DispatchWorkItem?
    private var lastLinkTarget: (id: UUID, name: String)?
    /// QF14/Fix #25: bounded backoff state — attempt index into `retryDelays`
    /// (the ladder, not a one-shot flag) plus the last-attempt timestamp for
    /// the quiet-period budget reset.
    private var reconnectAttempts = 0
    private var lastRetryAt: Date?
    private let maxReconnectAttempts = 5
    private let retryDelays: [TimeInterval] = [6, 30, 60, 120, 300]
    /// Fix #25: commands rescued from a mid-pull disconnect, replayed on the
    /// fresh link once characteristics are live.
    private var pendingResume: [QueuedCommand] = []
    /// Set by `disconnect()` so the later `didDisconnectPeripheral` callback
    /// doesn't schedule an auto-retry for a teardown the user asked for.
    private var userDisconnectPending = false

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

    /// Adds to the scan list, keyed by peripheral id — one row per watch with
    /// the best RSSI and freshest name kept (QF7, audit #1: the previous
    /// whole-struct `contains` check let the same watch re-appear whenever its
    /// advertised RSSI changed).
    private func upsertScanEntry(_ entry: DiscoveredWatch) {
        if let i = foundWatches.firstIndex(where: { $0.id == entry.id }) {
            let existing = foundWatches[i]
            foundWatches[i] = DiscoveredWatch(
                id: entry.id,
                name: entry.name.isEmpty ? existing.name : entry.name,
                rssi: max(existing.rssi, entry.rssi))
            foundWatches.sort { $0.rssi > $1.rssi }
        } else {
            foundWatches.append(entry)
            foundWatches.sort { $0.rssi > $1.rssi }
        }
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
        connectStored(peripheralId: watch.id, name: watch.name)
    }

    // MARK: Reconnect from persisted inventory (issue #43)

    /// Deferred reconnect while Bluetooth powers up.
    private var deferredReconnect: (id: UUID, name: String)?

    /// Reconnects to the stored watch when this view opens (hub row tap).
    /// No-op unless the link is idle/failed — never fights an active flow.
    func reconnectIfPaired() {
        switch stage {
        case .idle, .failed: break
        default: return
        }
        reconnectAttempts = 0   // QF14/Fix #25: explicit user action starts a fresh ladder
        Task { @MainActor in
            guard let stored = DeviceStore.shared.devices.first(where: { $0.kind == .watch })
            else { return }
            if central.state == .poweredOn {
                connectStored(peripheralId: stored.peripheralId, name: stored.name)
            } else {
                // Bluetooth still powering up — run it from didUpdateState.
                deferredReconnect = (stored.peripheralId, stored.name)
                appendLog("waiting for Bluetooth to connect \(stored.name)…")
            }
        }
    }

    /// Direct connect from a persisted peripheral UUID; falls back to a
    /// name-filtered rescan when iOS no longer caches the peripheral (#37).
    private func connectStored(peripheralId: UUID, name: String) {
        lastLinkTarget = (peripheralId, name)   // QF14: auto-retry target
        userDisconnectPending = false           // fresh link — honor its callbacks
        pendingPair = peripheralId
        registerInInventory(peripheralId: peripheralId, name: name)
        resetLink()
        if let p = central.retrievePeripherals(withIdentifiers: [peripheralId]).first {
            peripheral = p
            p.delegate = self
            central.connect(p)
            stage = .connecting
        } else {
            appendLog("watch not cached — rescanning to reconnect")
            scanAndPair(nameFilter: name)
        }
    }

    /// Fix #25: requeue commands that died with a dropped link. History and
    /// settings commands run again on the fresh connection; ONE-SHOT side
    /// effects (find-phone ack, camera status) are dropped instead of
    /// replaying events the watch already handled.
    private static func isResumable(_ c: QueuedCommand) -> Bool {
        switch c.ack {
        case .history, .steps, .workoutSummary, .phoneBook, .navigationStatus:
            return true
        case .sportStart, .sportEnd, .watchFaceSet, .navigationEvent:
            return false
        case .none:
            // Bare settings/info writes are safe to replay; control pushes
            // (find-phone ack, camera status) are not.
            switch c.bytes.first {
            case KahaProtocol.ClassId.info, KahaProtocol.ClassId.fitness,
                 KahaProtocol.ClassId.alerts:
                return true
            default:
                return false
            }
        }
    }

    /// Fix #25: requeue commands that died with a dropped link. History and
    /// settings commands run again on the fresh connection; ONE-SHOT side
    /// effects (find-phone ack, camera status) are dropped instead of
    /// replaying events the watch already handled.
    private static func isResumable(_ c: QueuedCommand) -> Bool {
        switch c.ack {
        case .history, .steps, .workoutSummary, .phoneBook, .navigationStatus:
            return true
        case .sportStart, .sportEnd, .watchFaceSet, .navigationEvent:
            return false
        case .none:
            // Bare settings/info writes are safe to replay; control pushes
            // (find-phone ack, camera status) are not.
            switch c.bytes.first {
            case KahaProtocol.ClassId.info, KahaProtocol.ClassId.fitness,
                 KahaProtocol.ClassId.alerts:
                return true
            default:
                return false
            }
        }
    }

    /// Fix #25 (audit #25): bounded reconnect backoff — 6 s → 30 s → 60 s →
    /// 2 min → 5 min, then manual only. Each failed attempt schedules the next
    /// (so the loop walks the ladder); the budget resets on `didConnect`, on
    /// explicit user reconnects, and after a ≥ 10 min quiet period (watch out
    /// of range for a while → fresh ladder when it fails again).
    private func scheduleReconnectRetry(reason: String) {
        guard let target = lastLinkTarget else { return }
        if reconnectAttempts >= maxReconnectAttempts {
            if let last = lastRetryAt, Date().timeIntervalSince(last) >= 600 {
                reconnectAttempts = 0   // quiet period elapsed — fresh ladder
            } else {
                appendLog("\(reason) — auto-retry budget spent; tap reconnect to try again")
                return
            }
        }
        lastRetryAt = Date()
        let attempt = reconnectAttempts
        reconnectAttempts += 1
        let delay = retryDelays[attempt]
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard case .failed = self.stage else { return }   // recovered, or a user flow took over
            self.appendLog("auto-retry \(attempt + 1)/5 in \(Int(delay)) s: reconnecting to \(target.name)…")
            self.connectStored(peripheralId: target.id, name: target.name)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        appendLog("\(reason) — auto-retry \(attempt + 1)/5 in \(Int(delay)) s")
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
        // QF14 (audit #25): user-initiated teardown — kill any pending
        // auto-retry first so the coming didDisconnectPeripheral callback
        // doesn't resurrect the link.
        userDisconnectPending = true
        reconnectAttempts = 0
        reconnectWork?.cancel()
        reconnectWork = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        handshakeDone = false
        resetLink()
        stage = .idle
    }

    // MARK: - History (SRD-010 §5 acceptance 3, #34/#41)

    /// Requests one day of HR/BP history (day = 0 → today). The response
    /// streams back as `0x7F` multipackets routed by the in-flight command.
    /// NOTE: no interval pre-command — the firmware streams at its own
    /// automatic-HR cadence (#45: the interval byte set via `01 02 05 00`
    /// would also collide with the history cmd id).
    func loadHRHistory(day: Int) {
        hrDay = day
        hrDated = []
        enqueue(KahaProtocol.requestHRHistory(day: day, startHour: 0, endHour: 23),
                label: "HR history day \(day)", ack: .history(.hr(day: day)))
    }

    /// Requests one day of 1-min sleep + periodic SpO2 history, strictly
    /// serialized. The official app requests 1-minute sleep resolution
    /// (`SleepDataReq` → `GET_1MIN_SLEEP_DATA`, 15 bytes/hour) — #48 fixed by
    /// switching off the legacy 10-min variant. Results persist into
    /// `WatchStore` (SRD-010 FR-2).
    func loadSleepAndSpo2History(day: Int) {
        sleepHours = []
        spo2Samples = []
        enqueue(KahaProtocol.requestSleepHistory1Min(day: day, startHour: 0, endHour: 23),
                label: "sleep history (1-min) day \(day)", ack: .history(.sleep(day: day)))
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
            self.forceCompleteInFlight()
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

    /// QF8 (audit #5): force-completing a history command mid-stream must
    /// discard the partial `0x7F` reassembly — otherwise the leftover stream
    /// fragments are decoded under the NEXT command's decoder kind and the
    /// day's data lands nowhere ("no in-flight decoder").
    private func forceCompleteInFlight() {
        if case .history? = commandInFlight?.ack {
            assembler.reset()
        }
        completeInFlight()
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
        sawBatteryChar = false
        handshakeDone = false
        assembler.reset()
        reconnectWork?.cancel()   // QF14: a new link attempt supersedes any pending auto-retry
        pendingResume = []
        queue.removeAll()
        ackTimer?.cancel()
        ackTimer = nil
        commandInFlight = nil
        sportRetryPending = false
        // Keep `sportStartUnsupported` across reconnects — it is a device
        // capability, not link state (#49).
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
        enqueue(KahaProtocol.infoFrame(cmdId: KahaProtocol.InfoCmd.getHardwareVersion),
                label: "get hardware version")   // QF6 (audit #6): GET_HARDWARE_VERSION = 00 01 04 00
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
        // Today's steps — the watch does NOT push them on connect; Crest asks
        // explicitly. QF11 (audit #10/#15): ask for the full daily summary via
        // GET_TODAY_FITNESS `01 2f` (u32 steps + distance + calories),
        // matching the official flow, instead of the u16-capped
        // GET_WALK_VALUE `01 00`.
        enqueue(KahaProtocol.requestTodaysFitness(),
                label: "today's fitness", ack: .steps)
        // Fix #25: replay commands rescued from a mid-pull disconnect — this
        // is the same point the handshake starts, so characteristics are live
        // and the strict queue drains them in order.
        if !pendingResume.isEmpty {
            queue.append(contentsOf: pendingResume)
            appendLog("resuming \(pendingResume.count) command(s) from before the drop")
            pendingResume = []
        }
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

        // --- Today's steps/fitness response (response class 0x81, cmd 0x00 or
        // 0x2f) — QF11 (audit #10/#15): the decompiled parser reads u32 steps
        // + distance/calories floats from this family, not just the legacy
        // u16. As steps (`.steps` ack) it feeds the Live card; as the day-0
        // summary (`.workoutSummary(0)`) it fills the Workouts card. Both
        // shapes decode via `decodeTodaysFitness`. Only accepted while a
        // steps/fitness request is in flight — the queue guarantees that
        // (decompiled `commandObject` parity, #44).
        case (KahaProtocol.ClassId.responseFitness, 0x00),
             (KahaProtocol.ClassId.responseFitness, KahaProtocol.FitnessCmd.todaysFitness):
            if commandInFlight?.ack == .steps,
               let fit = KahaProtocol.decodeTodaysFitness(frame.payload) {
                liveSteps = KahaProtocol.LiveSteps(
                    steps: fit.steps,
                    meters: fit.meters ?? liveSteps?.meters,
                    calories: fit.calories ?? liveSteps?.calories)
                persistLiveSteps()
                appendLog("today's fitness: \(fit.steps) steps" +
                          (fit.meters.map { String(format: " · %.0f m", $0) } ?? "") +
                          (fit.calories.map { String(format: " · %.0f kcal", $0) } ?? ""))
            } else if commandInFlight?.ack == .workoutSummary(day: 0),
                      let d = decodeWorkoutSummary(frame.payload, day: 0) {
                applyWorkoutDay(d)
                appendLog("workout day -\(d.id): \(d.steps) steps · \(Int(d.distanceMeters)) m · \(Int(d.calories)) kcal")
            }

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
        // #46: switch ack `82 8F` — payload[0] = 1 means the watch applied the
        // face; only then update the selection (SetCurrentWatchFaceRes parity).
        case (KahaProtocol.ClassId.responseAlerts, KahaProtocol.SystemCmd.watchFaceSet):
            if case .watchFaceSet(let id) = commandInFlight?.ack,
               KahaProtocol.decodeSportAck(frame.payload) == true {
                currentWatchFaceId = id
                appendLog("watch face \(id) active")
            } else {
                appendLog("watch face switch refused (ack \(frame.payload.hexString))")
            }

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
                // #49: the Storm Call 3 does not accept app-started workouts —
                // the official app declares this device
                // `sportModeSupportedFromApp = false` and never sends `01 8B`.
                // Surface it once and hide the controls instead of retrying.
                sportStartUnsupported = true
                sportSession = nil
                appendLog("watch refused sport mode (raw ack \(payload.hexString)) — this model only starts workouts from the watch itself")
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

    /// (Retained for devices whose firmware accepts `01 8B`; the Storm Call 3
    /// is exempted above per the official app's capability flag, #49.)
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
        case KahaProtocol.InfoCmd.getHardwareVersion:
            hardwareVersion = frame.payload.asciiString   // QF6 (audit #6)
        case KahaProtocol.InfoCmd.getFirmwareVersion:
            // #47: the version string often ends with NUL padding (and older
            // firmwares prepend a length byte) — `asciiString` treats NUL as
            // content and returned nil, leaving the field blank. Trim NULs
            // first, then fall back to the printable subset, then a hex dump
            // so the field is never silently empty.
            let nulTrimmed = frame.payload.filter { $0 != 0 }
            if let s = nulTrimmed.asciiString {
                firmwareVersion = s
            } else {
                let printable = frame.payload.filter { (0x20..<0x7F).contains($0) }
                firmwareVersion = printable.isEmpty
                    ? frame.payload.hexString
                    : String(bytes: printable, encoding: .ascii)
                appendLog("firmware raw payload: \(frame.payload.hexString)")
            }
            appendLog("firmware = \(firmwareVersion ?? "?")")
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

    /// QF11 (audit #15): single upsert path for workout-day summaries —
    /// replace in place for a known day, newest day goes to the front.
    /// Fix #15: the summary also lands in `WatchStore` (steps/calories/
    /// distance fields already existed; previously `workoutDays` died with
    /// the session and Stored-days rows stayed empty for pulled days).
    /// Idempotent: re-pulls REPLACE the day's values (same merge semantics
    /// as `upsert` for every other metric).
    private func applyWorkoutDay(_ d: WorkoutDay) {
        if let i = workoutDays.firstIndex(where: { $0.id == d.id }) {
            workoutDays[i] = d
        } else {
            workoutDays.insert(d, at: 0)
        }
        let date = Calendar.current.date(byAdding: .day, value: -d.id, to: Date()) ?? Date()
        let key = WatchStore.dayKey(for: date)
        let dayStart = Calendar.current.startOfDay(for: date)
        Task { @MainActor in
            WatchStore.shared.upsert(day: key, dayStart: dayStart,
                                     steps: d.steps, calories: d.calories,
                                     distanceMeters: d.distanceMeters)
        }
    }

    /// Reacts to watch-initiated control pushes (#25/#26/#30/#35/#36).
    private func handleWatchEvent(_ event: KahaProtocol.WatchControlEvent) {
        switch event {
        case .findMyPhone:
            // #35: ring + vibrate the phone, not just a notification.
            // QF9 (audit #21): FIND_MY_PHONE_ACK = 81 05 05 00 01 — the official
            // app confirms ringing started so the watch clears its "searching" UI.
            enqueue(KahaProtocol.frame(classId: 0x81, cmdId: 0x05, payload: [0x01]),
                    label: "find-phone ack")
            Task { @MainActor in
                FindPhoneCoordinator.shared.begin()
            }
            appendLog("watch asks: find my phone — ringing & vibrating")
        case .cameraEnter:
            // QF13 (audit #20): the shutter event usually follows within a
            // second — pre-heat the capture session now so the first
            // watch-triggered shot doesn't pay session start-up lag.
            Task { @MainActor in
                WatchCameraCoordinator.shared.warmUp()
            }
            appendLog("watch: camera remote — session warming up")
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
            // QF12 (audit #19): the watch's transport keys drive the phone's
            // media session (MusicRemoteCoordinator), not just the log.
            Task { @MainActor in
                MusicRemoteCoordinator.shared.apply(event)
            }
            appendLog("watch music: \(event)")
        }
    }

    // MARK: - Phone → watch controls (#23/#24/#25/#26/#30)

    /// QF2 (audit #17): title + body framed as `title\nbody` (first line renders
    /// as the header on the watch) and clipped to the model's 200-char limit
    /// (`maxCharSupportedInNotification`, StormCall3BleApiImpl) — not 58.
    func sendNotification(title: String, body: String, type: UInt8 = 18) {
        for f in KahaProtocol.sendNotificationMessage(title: title, body: body, type: type) {
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
        // #46: the switch ack (`82 8F`) updates the UI selection — the watch
        // must confirm before we show the new id as active.
        enqueue(KahaProtocol.setWatchFace(id: id), label: "watch face → \(id)",
                ack: .watchFaceSet(id: id))
    }

    /// #50: syncs ContactsKit entries to the watch (name + number, 20 bytes
    /// each, multipacket + CRC16 like the official app's SetPhoneBookReq).
    /// QF5 (audit #18): the official app caps ONE phone-book request at 20
    /// contacts (`setMaxContactsInOneRequest(20)`, StormCall3BleApiImpl) —
    /// larger lists are split into sequential requests.
    func syncContacts(_ contacts: [(name: String, number: String)]) {
        guard !contacts.isEmpty, contacts.count <= 100 else {
            appendLog("contacts: nothing to sync (100 max in Yantra)")
            return
        }
        for batch in stride(from: 0, to: contacts.count, by: 20).map({
            Array(contacts[$0..<min($0 + 20, contacts.count)])
        }) {
            for f in KahaProtocol.phoneBook(batch) {
                enqueue(f, label: "contact sync (\(batch.count))", ack: .phoneBook)
            }
        }
    }

    /// #60: starts navigation on the watch (start marker + status 2, Crest
    /// `setNavigationStartOrStopOnBand` parity).
    func startNavigation(destination: String, mode: KahaProtocol.NavigationMode) {
        enqueue(KahaProtocol.navigationEvent(source: "Current Location",
                                             destination: destination, mode: mode),
                label: "navigation → \(destination)", ack: .navigationEvent)
        enqueue(KahaProtocol.navigationStatus(2), label: "navigation status 2",
                ack: .navigationStatus)
    }

    /// #60: pushes a turn-by-turn event (destination + remaining distance).
    func updateNavigation(destination: String, remainingMeters: Int,
                          mode: KahaProtocol.NavigationMode) {
        enqueue(KahaProtocol.navigationEvent(source: "Current Location",
                                             destination: destination, mode: mode),
                label: "navigation update \(remainingMeters) m", ack: .navigationEvent)
    }

    /// #60: stops navigation on the watch (event=false + status 0).
    func stopNavigation() {
        enqueue(KahaProtocol.navigationStop(), label: "navigation stop", ack: .navigationEvent)
        enqueue(KahaProtocol.navigationStatus(0), label: "navigation status 0",
                ack: .navigationStatus)
    }

    func loadWorkoutDays(_ days: [Int]) {
        for d in days {
            // QF11 (audit #15): day 0 uses GET_TODAY_FITNESS `01 2f` (the
            // official app never sends `01 23 00` mid-day — it can return
            // yesterday-completed totals); n ≥ 1 uses the day summary `01 23`.
            if d == 0 {
                enqueue(KahaProtocol.requestTodaysFitness(),
                        label: "today's fitness", ack: .workoutSummary(day: 0))
            } else {
                enqueue(KahaProtocol.requestWorkoutSummary(daysAgo: d),
                        label: "workout summary day -\(d)", ack: .workoutSummary(day: d))
            }
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
            // #48: 1-min sleep streams 15 bytes/hour; the legacy 10-min
            // layout (6 bytes/hour) stays supported for older firmware.
            let bytesPerHour = data.count % 15 == 0 ? 15 : 6
            sleepHours = KahaProtocol.decodeSleepHistory(data, startHour: 0,
                                                         bytesPerHour: bytesPerHour)
            persistSleepDay()
            let total = sleepHours.reduce(0.0) { $0 + $1.totalSleepMinutes }
            appendLog("sleep history (\(bytesPerHour == 15 ? "1" : "10")-min): \(sleepHours.count) hours · \(String(format: "%.0f", total)) min sleep")
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
            // QF11 (audit #15): shared upsert — the plain `81 2f` reply path
            // in `handleFrame` lands in the same store.
            if let d = decodeWorkoutSummary(data, day: day) {
                applyWorkoutDay(d)
                appendLog("workout day -\(d.id): \(d.steps) steps · \(Int(d.distanceMeters)) m · \(Int(d.calories)) kcal")
            }
            completeInFlight()
        case .phoneBook:
            appendLog("contacts synced to watch (\(data.count) B ack)")
            completeInFlight()
        case .navigationStatus, .navigationEvent:
            appendLog("navigation ack (\(data.count) B)")
            completeInFlight()
        case .watchFaceSet(let id):
            // `82 8F` streams through the assembler too; treat any assembled
            // payload as the ack and apply the pending id (#46).
            if KahaProtocol.decodeSportAck(data) == true {
                currentWatchFaceId = id
                appendLog("watch face \(id) active")
            } else {
                appendLog("watch face switch refused (ack \(data.hexString))")
            }
            completeInFlight()
        case .steps:
            // QF11 (audit #10): reply shapes this ack catches — the 3-byte
            // `type + u16` legacy body and the ≥12-byte full fitness shape
            // (u32 steps @0 + gated distance/calories floats), both via
            // `decodeTodaysFitness`. Some firmware revisions also answer
            // with a 0x0D-headered stream (seen live: `cmd 0x0D, 1152
            // bytes`); anything undecodable logs a hex dump.
            if let fit = KahaProtocol.decodeTodaysFitness(data) {
                let live = KahaProtocol.LiveSteps(
                    steps: fit.steps,
                    meters: fit.meters ?? liveSteps?.meters,
                    calories: fit.calories ?? liveSteps?.calories)
                liveSteps = live
                persistLiveSteps()
                appendLog("today's steps: \(fit.steps)")
            } else {
                appendLog("today's steps: undecodable payload (\(data.count) B: \(Array(data.prefix(12)).hexString))")
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
        guard central.state == .poweredOn else { return }
        if let d = deferredReconnect {
            deferredReconnect = nil
            connectStored(peripheralId: d.id, name: d.name)
        } else if stage == .scanning {
            // No service filter (#38): the Realtek/KaHa watch does not advertise
            // the Nordic UART UUID — the official app scans by name only.
            central.scanForPeripherals(withServices: nil, options: nil)
        }
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
        upsertScanEntry(entry)   // QF7: one row per watch, best RSSI kept
        // Auto-pair on first hit when pairing was initiated by QR/MAC or by a
        // cache-miss retry (issue #37).
        if connectTargetName != nil || pendingPair != nil {
            stopScan()
            pendingPair = peripheral.identifier
            userDisconnectPending = false   // fresh link — honor its callbacks
            resetLink()
            peripheral.delegate = self
            central.connect(peripheral)
            registerInInventory(peripheralId: peripheral.identifier, name: n)
            stage = .connecting
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // QF14/Fix #25: link is up — retry ladder fully restored.
        reconnectAttempts = 0
        lastRetryAt = nil
        appendLog("GATT connected — discovering services")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        stage = .failed("connect failed: \(error?.localizedDescription ?? "unknown")")
        scheduleReconnectRetry(reason: "connect failed")   // QF14 (audit #25)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // QF14 (audit #25): a user-initiated teardown already went through
        // `disconnect()` — honor it (stay idle) instead of flagging a failure.
        if userDisconnectPending {
            userDisconnectPending = false
            return
        }
        handshakeDone = false
        // Fix #25: rescue resumable work (history pulls, today's fitness,
        // settings) instead of dropping it — replayed on the fresh link once
        // characteristics are live, in original order (in-flight ran first).
        // One-shot effects (find-phone ack, sport control) are intentionally
        // not replayed.
        var rescued: [QueuedCommand] = []
        if let c = commandInFlight, Self.isResumable(c) { rescued.append(c) }
        rescued.append(contentsOf: queue.filter(Self.isResumable))
        if !rescued.isEmpty {
            pendingResume = rescued
            appendLog("link lost mid-pull — \(rescued.count) command(s) queued for resume")
        }
        queue.removeAll()
        commandInFlight = nil
        stage = .failed(error == nil ? "watch disconnected" : "disconnected: \(error!.localizedDescription)")
        scheduleReconnectRetry(reason: "unexpected disconnect")   // QF14/Fix #25
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
            if c.uuid == cb(KahaProtocol.GATT.batteryLevel) {
                sawBatteryChar = true   // QF10: present → its CCCD is required
            }
            if c.uuid == cb(KahaProtocol.GATT.uartRead) || c.uuid == cb(KahaProtocol.GATT.batteryLevel) {
                subscribe(c)
            }
            if c.uuid == cb(KahaProtocol.GATT.firmwareRevision), !firmwareReadPending {
                firmwareReadPending = true
                peripheral.readValue(for: c)
            }
        }
        // QF10 (audit #8): go live once the UART notify is up AND either the
        // battery CCCD subscribed or this firmware never exposed a battery
        // characteristic at all — demanding both CCCDs hung the whole
        // handshake on firmware without 0x2A19.
        if subscribed.contains(cb(KahaProtocol.GATT.uartRead)),
           subscribed.contains(cb(KahaProtocol.GATT.batteryLevel)) || !sawBatteryChar,
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
                // #47: NUL padding survives `.whitespacesAndNewlines` — strip
                // it explicitly or the field shows blank.
                firmwareVersion = String(data: v, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(["\0"]))
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
