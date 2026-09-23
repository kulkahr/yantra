import Foundation
import CoreBluetooth
import ScaleKit

/// Yantra's BLE central — a faithful port of the hardware-verified `BleHost`
/// pipeline (REPLICATION.md wire facts):
///   discovery → sequential reads (best effort) → CCCDs on ALL FOUR notifiable
///   channels (A620 indicate first — the challenge gate) → machine start →
///   `0x4801` arm → records stream as real-time `0x4802`.
final class ScaleCentral: NSObject, ObservableObject {

    /// SRD-009: shared instance so the Devices hub (and future drivers) can
    /// reach the scale flow without owning the object graph.
    static let shared = ScaleCentral()

    // MARK: - Published UI state

    enum Stage: Equatable {
        case idle
        case scanning
        case connecting
        case handshaking          // discovery + reads + CCCDs + login exchange
        case paired               // bind complete (pair flow)
        case live                 // session armed, waiting for weigh-in
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var bluetoothOn = false
    @Published private(set) var foundScales: [DiscoveredScale] = []
    @Published private(set) var lastRecord: MeasurementRecord?
    @Published private(set) var recordCount = 0
    @Published private(set) var log: [String] = []
    /// Battery % from the `A640` raw byte (SRD-006 FR-3); nil = not read yet.
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var batteryLow = false
    /// Device-info snapshot after the connect-time reads (SRD-006 FR-1).
    @Published private(set) var deviceInfo: [String: String] = [:]
    /// True while a session machine exists (gates clear-memory UI).
    var sessionMachineActive: Bool { sessionMachine != nil }
    /// DFU transfer progress (nil = no update running).
    @Published private(set) var dfuProgress: DfuStateMachine.Progress?
    @Published private(set) var dfuFinished: String?

    struct DiscoveredScale: Identifiable, Equatable {
        let id: UUID
        let name: String
        let mac: String
        let rssi: Int
    }

    // MARK: - Link state (ported from BleHost)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var chars: [UUID: CBCharacteristic] = [:]
    private var notifiesEnabled: Set<UUID> = []
    private var cccdStarted = false
    private var readsStarted = false
    private var readsComplete = false
    private var discoveredServices: Set<UUID> = []
    private var pendingReads: [UUID] = []
    private var readResults: [UUID: Data] = [:]
    private var disconnectRequested = false
    private var connectTarget: (id: UUID, mac: String)?
    /// Scale user slot used by the running session (active person's slot when set).
    private var sessionSlot: Int?
    /// Scale being bound (peripheral id + slot) — persisted into the bind record
    /// so later sessions can `retrievePeripherals(withIdentifiers:)` directly.
    private var pendingBind: (scaleId: UUID, slot: Int)?

    private enum Flow: Equatable { case pair(slot: Int), session(slot: Int, arm: Bool), dfu }
    private var flow: Flow?
    private var pairMachine: PairStateMachine?
    private var dfuMachine: DfuStateMachine?
    /// DFU-mode peripherals advertise `LsD…`/`LsDfu…` names (decompiled
    /// `isUpgradeModelDevice`) — scan matches on this prefix.
    private var dfuScanActive = false
    private var sessionMachine: SessionStateMachine?
    private var watchdog: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "firefly.watchdog")
    /// SRD-001 FR-5: foreground scan auto-stops after 30 s (official duty-cycle parity).
    private var scanTimeout: DispatchWorkItem?
    /// `--arm` parity: send `0x4801` once the machine reaches `.live`
    /// (wire fact #5 — records only flow after start-measurement).
    private var pendingArm = false

    /// Profile for the user-info push (0x1001) and body composition — the
    /// ACTIVE person's own metrics (every person carries a full profile, #3).
    var profile: SessionStateMachine.UserProfile {
        guard let p = PersonStore.shared.activePerson else {
            return ProfileStore.shared.machineProfile
        }
        return SessionStateMachine.UserProfile(
            sexMale: p.sexMale, age: p.age, heightMeters: p.heightCm / 100)
    }

    // MARK: - Public API

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        foundScales = []
        stage = .scanning
        guard central.state == .poweredOn else { return }
        scheduleScanTimeout()
        // Duplicate filtering ON — one didDiscover row per physical scale; RSSI
        // refresh handled in didDiscover (keyed by peripheral.identifier).
        central.scanForPeripherals(withServices: [cbuuid(GATT.a6Service)], options: nil)
    }

    /// SRD-001 FR-5 — 30 s foreground scan window, cancellable.
    private func scheduleScanTimeout() {
        scanTimeout?.cancel()
        let t = DispatchWorkItem { [weak self] in
            guard let self, self.stage == .scanning else { return }
            self.stopScan()
            self.appendLog("scan timed out (30 s)")
        }
        scanTimeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: t)
    }

    func stopScan() {
        scanTimeout?.cancel()
        scanTimeout = nil
        central.stopScan()
        if stage == .scanning { stage = .idle }
    }

    /// Bind the selected scale to `slot` (SRD-002).
    func bind(_ scale: DiscoveredScale, slot: Int) {
        connectTarget = (scale.id, scale.mac)
        flow = .pair(slot: slot)
        pendingBind = (scale.id, slot)
        resetLinkState()
        if let p = central.retrievePeripherals(withIdentifiers: [scale.id]).first {
            peripheral = p
            p.delegate = self
            central.connect(p)
            stage = .connecting
        } else {
            startScan()   // connects from didDiscover once seen
            stage = .connecting
        }
    }

    /// SRD-009 hub entry point: adopt a scale discovered by the driver
    /// registry's scanner and immediately run the standard bind handshake
    /// (slot 1 per issue #12 — user→slot mapping lives in People).
    func adoptDiscovered(_ adv: AdvertisementSnapshot) {
        guard let mac = ScaleCentral.macFromMfg(adv.manufacturerData), !mac.isEmpty else {
            stage = .failed("scale advertised no MAC — move closer and retry")
            return
        }
        let scale = DiscoveredScale(id: adv.peripheralId,
                                    name: adv.name ?? "Smart Scale",
                                    mac: mac, rssi: adv.rssi)
        bind(scale, slot: 1)
    }

    /// Open a weigh-in session with the bound scale (SRD-003).
    func startSession(with scale: DiscoveredScale, arm: Bool = true) {
        guard let rec = BindStore.shared.record else {
            stage = .failed("No bind record — pair the scale first")
            return
        }
        connectTarget = (scale.id, rec.mac)
        flow = .session(slot: rec.slot, arm: arm)
        resetLinkState()
        if let idStr = rec.peripheralId, let u = UUID(uuidString: idStr),
           let p = central.retrievePeripherals(withIdentifiers: [u]).first {
            peripheral = p
            p.delegate = self
            central.connect(p)
            stage = .connecting
        } else {
            // No persisted peripheral id (older bind record, or iOS re-assigned
            // identifiers) — scan and match the bound MAC at discovery time.
            appendLog("scanning for bound scale \(rec.mac) …")
            startScan()
            stage = .connecting
        }
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        pairMachine = nil
        sessionMachine = nil
        flow = nil
        pendingBind = nil
        stage = .idle
    }

    private func appendLog(_ s: String) {
        log.append(s)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    // MARK: - Link pipeline (port of BleHost, wire-verified)

    private func resetLinkState() {
        chars = [:]
        notifiesEnabled = []
        cccdStarted = false
        readsStarted = false
        readsComplete = false
        discoveredServices = []
        pendingReads = []
        readResults = [:]
        disconnectRequested = false
        pairMachine = nil
        sessionMachine = nil
        dfuMachine = nil
        pendingArm = false
        sessionSlot = nil
    }

    // MARK: - Firmware update (SRD-007)

    /// Starts a DFU update with a user-supplied firmware file. The scale must
    /// be in update mode (rebooted into DFU by the device itself — its
    /// advertisement name then starts with `LsD`/`LsDfu`).
    func startDfuUpdate(fileURL: URL, checkModel: String) {
        guard bluetoothOn else {
            stage = .failed("Bluetooth is off"); return
        }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            stage = .failed("Firmware file unreadable"); return
        }
        do {
            let img = try DfuImage.parse([UInt8](data))
            appendLog(String(format: "firmware file: %@ · bins %@ · %d bytes to transfer",
                             img.version.isEmpty ? "?" : img.version,
                             img.bins.map(\.type.rawValue).joined(separator: "+"),
                             img.allBinSize))
            var m = DfuStateMachine(image: img, checkModel: checkModel)
            _ = m.start()                      // phase = .connecting; connect happens post-scan
            resetLinkState()                   // clears machines — set ours after
            dfuMachine = m
            flow = .dfu
            dfuScanActive = true
            dfuProgress = m.progress
            dfuFinished = nil
            startScan()
            stage = .connecting
            appendLog("scanning for scale in update mode (LsDfu…) — press update on the scale if it has not rebooted yet")
        } catch let e as DfuImage.ParseError {
            switch e {
            case .tooSmall(let n): stage = .failed("Firmware file too small (\(n) bytes)")
            case .badMagic: stage = .failed("Not a Lifesense OTA container (bad magic)")
            case .emptyImage: stage = .failed("Firmware container has no images")
            }
        } catch {
            stage = .failed("Firmware parse error")
        }
    }

    private func beginReadsIfNeeded() {
        guard !readsStarted,
              let services = peripheral?.services, !services.isEmpty,
              discoveredServices.count == services.count else { return }
        readsStarted = true
        // Sequential reads — parallel reads stall on this firmware (wire-verified).
        let wanted: [UUID] = [GATTPlus.firmwareRevision, GATTPlus.modelNumber,
                              GATTPlus.manufacturerName, GATTPlus.serialNumber,
                              GATTPlus.hardwareRevision, GATT.featureInfo, GATT.voltage]
        pendingReads = wanted.filter { chars[$0] != nil }
        if pendingReads.isEmpty {
            readsComplete = true
            tryStartMachine()
        } else if let c = chars[pendingReads[0]] {
            peripheral?.readValue(for: c)
        }
        // 5 s failsafe — continue with partial reads.
        watchdogQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.readsComplete else { return }
                self.readsComplete = true
                self.tryStartMachine()
            }
        }
    }

    /// Builds the device-info strings shown on the Device page (SRD-006 FR-1).
    private static func infoSnapshot(from readResults: [UUID: Data]) -> [String: String] {
        func text(_ u: UUID) -> String? {
            guard let data = readResults[u],
                  let raw = String(data: data, encoding: .utf8) else { return nil }
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\0"))
            return trimmed.isEmpty ? nil : trimmed
        }
        var info: [String: String] = [:]
        if let v = text(GATTPlus.modelNumber) { info["Model"] = v }
        if let v = text(GATTPlus.manufacturerName) { info["Manufacturer"] = v }
        if let v = text(GATTPlus.serialNumber) { info["Serial"] = v }
        if let v = text(GATTPlus.hardwareRevision) { info["Hardware"] = v }
        if let v = text(GATTPlus.firmwareRevision) { info["Firmware"] = v }
        return info
    }

    private func tryStartMachine() {
        guard readsComplete, flow != nil,
              pairMachine == nil, sessionMachine == nil else { return }
        if !cccdStarted {
            cccdStarted = true
            // THE GATE (wire fact #2): subscribe all four notifiable channels —
            // A620 indicate FIRST — or the scale never challenges us.
            let wanted = [GATTPlus.a6Broadcast, GATT.notifyData, GATT.notifyAck, GATTPlus.otaData]
                .filter { chars[$0] != nil }
            appendLog("subscribing \(wanted.map(shortName).joined(separator: ","))")
            for u in wanted { if let c = chars[u] { peripheral?.setNotifyValue(true, for: c) } }
            return
        }
        guard notifiesEnabled.contains(GATT.notifyData),
              notifiesEnabled.contains(GATT.notifyAck) else { return }

        // 2A26 may carry trailing NULs/whitespace — trim before the XOR-variant
        // string comparison (and before persisting into the bind record).
        let fw = readResults[GATTPlus.firmwareRevision]
            .flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\0")) ?? ""
        let effectiveFw = fw.isEmpty ? "1.5.0.0" : fw   // XOR-variant default
        // Issue #10: bind records created before the #8 read fix persist the
        // stale 1.5.0.0 default forever (DeviceView shows the bind record).
        // The live 2A26 read is authoritative — refresh the stored value when
        // it differs so the UI and future sessions agree with the hardware.
        if var bind = BindStore.shared.record, !fw.isEmpty, bind.firmwareVersion != fw {
            bind.firmwareVersion = fw
            BindStore.shared.record = bind
            appendLog("fw refreshed from device: \(fw)")
        }
        // SRD-006 FR-1/FR-2/FR-3: surface identity fields, feature bitmap and
        // battery from the connect-time reads.
        deviceInfo = Self.infoSnapshot(from: readResults)
        if let raw = readResults[GATT.voltage].map({ $0.count > 0 ? Int($0[$0.startIndex]) : nil }) ?? nil {
            batteryPercent = Battery.percent(rawByte: raw)
            batteryLow = Battery.isLow(rawByte: raw)
        }
        if let feat = readResults[GATT.featureInfo].map({ [UInt8]($0) }), !feat.isEmpty {
            BindStore.shared.featureBitmap = feat
        }
        let mac = connectTarget?.mac
            ?? BindStore.shared.record?.mac
            ?? ""

        switch flow {
        case .pair(let slot):
            var m = PairStateMachine(config: .init(
                mac: mac, firmwareVersion: effectiveFw,
                mode: .bind, userSlot: slot, registerState: .normalUnregister))
            _ = m.start()
            _ = m.handle(.connected)
            _ = m.handle(.servicesDiscovered)
            _ = m.handle(.notifyEnabled(characteristic: GATT.notifyData))
            var pairOut = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))
            // Host gates after the read phase (PairDriver parity — without these
            // the machine parks in .readingDeviceInfo and nothing is ever sent):
            if m.phase == .readingDeviceInfo {
                let feat = readResults[GATT.featureInfo].map { [UInt8]($0) } ?? []
                pairOut.actions += m.handle(.readResponse(
                    characteristic: GATT.featureInfo, data: feat)).actions
            }
            if case .awaitingDeviceIdInput = m.phase {
                // Fresh-scale path: 0x0001 register with deviceId = MAC hex
                // (hardware-verified REPLICATION.md recipe).
                pairOut.actions += m.setDeviceIdInput(A6Obfuscation.macHex(mac)).actions
            }
            if case .awaitingChallenge = m.phase {
                appendLog("⏳ waiting for the scale's challenge — step on the scale now")
            }
            pairMachine = m
            performAll(pairOut.actions)
            appendLog("pair machine started (fw \(effectiveFw))")
        case .session(let slot, let arm):
            // Multi-user: the ACTIVE person's slot drives 0x4801 arm + user-info
            // push, so the scale attributes the measurement to that slot.
            let activeSlot = PersonStore.shared.activePerson?.slot ?? slot
            sessionSlot = activeSlot
            // SRD-005 FR-4: unit + formula from user settings; target from the
            // active person's goal (nil → not pushed).
            let cfg = ScaleConfigStore.shared
            let targetKg = PersonStore.shared.activePerson?.targetWeightKg
            var m = SessionStateMachine(config: .init(
                mac: mac, firmwareVersion: effectiveFw,
                deviceId: BindStore.shared.record?.deviceId
                    ?? mac.replacingOccurrences(of: ":", with: "").lowercased(),
                slot: activeSlot, unit: cfg.unit, profile: profile,
                formula: cfg.formula, targetKg: targetKg,
                utcProvider: { UInt32(Date().timeIntervalSince1970) },
                timeZoneHex: {
                    // (offsetMinutes / 15) + 48 — wire-verified (IST → 0x46).
                    let minutes = TimeZone.current.secondsFromGMT() / 60
                    return UInt8(truncatingIfNeeded: (minutes / 15) + 48)
                },
                dateProvider: {
                    let c = Calendar(identifier: .gregorian).dateComponents(
                        [.year, .month, .day, .hour, .minute, .second], from: Date())
                    return (c.year ?? 2026, c.month ?? 1, c.day ?? 1,
                            c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
                }))
            _ = m.start()
            _ = m.handle(.connected)
            _ = m.handle(.servicesDiscovered)
            _ = m.handle(.notifyEnabled(characteristic: GATT.notifyData))
            _ = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))
            sessionMachine = m
            pendingArm = arm
            appendLog("session machine started (fw \(effectiveFw))")
        case .dfu, nil:
            break   // DFU is dispatched through dfuDrive, not tryStartMachine
        }
        if stage != .paired { stage = .handshaking }
        syncWatchdog()
    }

    // MARK: - Watchdog (3 s ACK resend — decompiled constant)

    private func syncWatchdog() {
        // Arm while a command is in flight — frames still to write OR waiting
        // for the device ACK (3 s resend, BleHost.Watchdog.sync parity).
        let pairPending = pairMachine.map { $0.queue.isWritePending || !$0.queue.isEmpty } ?? false
        let sessionPending = sessionMachine.map { $0.queue.isWritePending || !$0.queue.isEmpty } ?? false
        let pending = pairPending || sessionPending
        if pending, watchdog == nil {
            let t = DispatchSource.makeTimerSource(queue: watchdogQueue)
            t.schedule(deadline: .now() + 3.0)
            t.setEventHandler { [weak self] in
                DispatchQueue.main.async { self?.resendTimedOut() }
            }
            watchdog = t
            t.resume()
        } else if !pending, let w = watchdog {
            w.cancel()
            watchdog = nil
        }
    }

    private func resendTimedOut() {
        watchdog = nil
        if pairMachine != nil {
            var m = pairMachine!
            let out = m.handle(.commandTimedOut)
            pairMachine = m
            performAll(out.actions)
        }
        if sessionMachine != nil {
            var m = sessionMachine!
            let out = m.handle(.commandTimedOut)
            sessionMachine = m
            performAll(out.actions)
            collectRecords(out)
        }
        syncWatchdog()
    }

    // MARK: - Event dispatch

    private func dispatch(_ event: LinkEvent) {
        if pairMachine != nil {
            var m = pairMachine!
            var out = m.handle(event)
            // Host decision gate (PairDriver parity): the machine parks in
            // .awaitingBindConfirm until the host confirms — confirm immediately
            // or the bind never completes (0x0003 bind notice is never sent).
            if case .awaitingBindConfirm = m.phase {
                out.actions += m.setBindConfirm(.pairingSuccess, slot: m.config.userSlot).actions
            }
            pairMachine = m
            performAll(out.actions)
            if let bind = out.bindRecord {
                BindStore.shared.record = .init(
                    deviceId: bind.deviceId, mac: bind.mac, slot: bind.slot,
                    firmwareVersion: bind.firmwareVersion, boundAt: bind.boundAt,
                    peripheralId: pendingBind?.scaleId.uuidString)
                pendingBind = nil
                stage = .paired
                appendLog("BOUND ✓ deviceId \(bind.deviceId)")
            }
            if case .failed(let f) = m.phase { stage = .failed(pairFailureText(f)) }
        }
        if sessionMachine != nil {
            var m = sessionMachine!
            let out = m.handle(event)
            sessionMachine = m
            performAll(out.actions)
            collectRecords(out)
            // SRD-005 FR-3: surface echo mismatches / rejected settings.
            for mismatch in out.echoMismatches {
                appendLog("⚠ scale echo: \(mismatch)")
            }
            for rejected in out.rejectedSettings {
                appendLog(String(format: "⚠ scale rejected setting 0x%02X", rejected))
            }
            if m.phase == .live, pendingArm {
                pendingArm = false
                let armOut = m.startMeasurement()
                sessionMachine = m
                performAll(armOut.actions)
                stage = .live
                appendLog("armed (0x4801) — step on the scale")
            }
            if case .failed(let e) = m.phase { stage = .failed(sessionErrorText(e)) }
        }
        syncWatchdog()
    }

    private func collectRecords(_ out: SessionStateMachine.Output) {
        guard let deviceId = BindStore.shared.record?.deviceId else { return }
        let slot = sessionSlot ?? BindStore.shared.record?.slot ?? 1
        // Issue #6: only records measured NOW belong to the active person.
        // Records drained from scale memory (weighed while disconnected —
        // possibly by someone else) carry their own UTC and must not be
        // silently attributed to whoever happens to be active now; they stay
        // unassigned for the History assignment flow. Freshness window:
        // 10 min (weigh-in ≤ a few minutes + clock drift).
        let activePersonId = PersonStore.shared.activePersonId
        let now = Date()
        for rec in out.measurements {
            var stored = MeasurementRecord(deviceId: deviceId, slot: slot,
                                           personId: activePersonId,
                                           from: rec)
            // Issue #9: attribution only for weigh-ins measured NOW. The
            // protocol signal is primary — `remainCount > 0` means the scale is
            // emptying stored memory (weighed while disconnected, possibly by
            // someone else). Timestamp (≤10 min, ≤60 s in the future) is the
            // secondary guard against a live record from a pre-session person.
            let drained = rec.fromMemoryDrain
                || now.timeIntervalSince(stored.utc) > 600
                || stored.utc > now.addingTimeInterval(60)
            if drained { stored.personId = nil }
            if MeasurementStore.shared.insert(stored) {
                recordCount += 1
                lastRecord = stored
                appendLog(String(format: "✔ %.2f kg%@ (impedance %@)",
                                 rec.weightKg,
                                 drained ? " · drained" : "",
                                 rec.impedanceOhm.map(String.init) ?? "-"))
            }
        }
    }

    private func pairFailureText(_ f: PairStateMachine.A6PairError) -> String {
        switch f {
        case .registerRejected: return "register rejected by scale"
        case .bindRefused: return "bind refused by scale"
        case .timeout: return "pairing timed out"
        case .bluetoothClosed: return "bluetooth turned off"
        case .userCancelled: return "cancelled"
        case .featureNotBindable: return "scale reports not bindable"
        case .ackResendExhausted: return "scale stopped ACKing"
        case .protocolError(let s): return "protocol error: \(s)"
        }
    }

    private func sessionErrorText(_ e: SessionStateMachine.A6SessionError) -> String {
        switch e {
        case .ackResendExhausted: return "scale stopped ACKing"
        case .protocolError(let s): return "protocol error: \(s)"
        case .userCancelled: return "cancelled"
        }
    }

    /// `0x1005` clear-scale-memory (SRD-004 FR-4) — user-confirmed via dialog;
    /// requires a live session so the command flows over an established link.
    func clearScaleMemory() {
        guard var m = sessionMachine else {
            appendLog("⚠ clear-memory needs a live session")
            return
        }
        let out = m.clearScaleMemory()
        sessionMachine = m
        performAll(out.actions)
        appendLog("clear-memory (0x1005) sent — scale erases stored records")
    }

    // MARK: - DFU dispatch

    /// Feeds an event to the DFU state machine and performs its actions.
    private func dfuDrive(_ event: LinkEvent) {
        guard var m = dfuMachine else { return }
        let out = m.handle(event)
        dfuMachine = m
        dfuProgress = out.progress
        for a in out.actions {
            switch a {
            case .write(let uuid, let data):
                perform(.write(characteristic: uuid, data: data))
            case .disconnect:
                perform(.disconnect)
            default:
                break
            }
        }
        if out.finished {
            dfuFinished = "Update complete — scale is rebooting into the new firmware."
            dfuProgress = m.progress
            appendLog("DFU ✓ \(dfuFinished!)")
            flow = nil
            dfuMachine = nil
            dfuScanActive = false
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            stage = .idle
        } else if case .failed(let msg) = m.phase {
            dfuFinished = "Update failed: \(msg)"
            appendLog("DFU ✗ \(msg)")
            flow = nil
            dfuMachine = nil
            dfuScanActive = false
            stage = .idle
        }
    }

    // MARK: - Actions

    private func performAll(_ actions: [LinkAction]) {
        for a in actions { perform(a) }
    }

    private func perform(_ action: LinkAction) {
        switch action {
        case .write(let uuid, let data):
            guard let c = chars[uuid] else {
                appendLog("!! write to unknown characteristic \(uuid.uuidString)")
                return
            }
            let withResponse = c.properties.contains(.write)
            let hex = data.map { String(format: "%02X", $0) }.joined()
            appendLog("→ \(shortName(uuid)) \(hex)\(withResponse ? "" : " (nr)")")
            peripheral?.writeValue(Data(data), for: c,
                                   type: withResponse ? .withResponse : .withoutResponse)
        case .disconnect:
            guard !disconnectRequested else { return }
            disconnectRequested = true
            if let p = peripheral { central.cancelPeripheralConnection(p) }
        default:
            break   // connect/discover/notify/read are host-driven
        }
    }

    // MARK: - Helpers

    private func shortName(_ uuid: UUID) -> String {
        switch uuid {
        case GATT.notifyData: return "A621"
        case GATT.notifyAck: return "A625"
        case GATT.writeData: return "A624"
        case GATT.writeAck: return "A622"
        case GATTPlus.a6Broadcast: return "A620"
        case GATTPlus.otaData: return "1531"
        case DfuGATT.packet: return "1532"
        case DfuGATT.version: return "1534"
        case GATT.featureInfo: return "A641"
        case GATT.voltage: return "A640"
        case GATTPlus.firmwareRevision: return "2A26"
        case GATTPlus.hardwareRevision: return "2A27"
        case GATTPlus.modelNumber: return "2A24"
        case GATTPlus.serialNumber: return "2A25"
        case GATTPlus.manufacturerName: return "2A29"
        default: return String(uuid.uuidString.prefix(4))
        }
    }

    /// Foundation UUID → CBUUID (CoreBluetooth accepts the full 128-bit form).
    private func cbuuid(_ u: UUID) -> CBUUID { CBUUID(string: u.uuidString) }

    /// CBUUID → Foundation UUID, expanding 16-bit aliases to the base UUID
/// (port of BleHost.f — GATT constants are full-form Foundation UUIDs).
    private func f(_ c: CBUUID) -> UUID {
        let s = c.uuidString.uppercased()
        if s.count == 4 {
            return UUID(uuidString: "0000\(s)-0000-1000-8000-00805F9B34FB")!
        }
        return UUID(uuidString: s) ?? UUID()
    }

    /// Advertised mfg trailing 6 bytes are the MAC **reversed** (wire fact #1).
    static func macFromMfg(_ mfg: Data?) -> String? {
        guard let d = mfg, d.count >= 8 else { return nil }
        let bytes = [UInt8](d.suffix(6).reversed())
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Upsert into `foundScales` keyed by peripheral identifier (one row per
    /// physical scale), keeping the best RSSI and freshest name. Insert sorted
    /// strongest-signal-first.
    private func upsertScanEntry(_ entry: DiscoveredScale) {
        if let i = foundScales.firstIndex(where: { $0.id == entry.id }) {
            let old = foundScales[i]
            foundScales[i] = DiscoveredScale(
                id: entry.id,
                name: entry.name.isEmpty ? old.name : entry.name,
                mac: entry.mac,
                rssi: max(old.rssi, entry.rssi))
        } else {
            let pos = foundScales.firstIndex { $0.rssi < entry.rssi } ?? foundScales.count
            foundScales.insert(entry, at: pos)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension ScaleCentral: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothOn = central.state == .poweredOn
        if bluetoothOn, stage == .scanning { startScan() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        guard let mac = ScaleCentral.macFromMfg(mfg) else { return }

        // Active connect target (bind/session) — connect the moment we see it.
        // Session fallback matches the bound MAC (peripheral id can be re-assigned).
        if let t = connectTarget, flow != nil, peripheral.state != .connected,
           t.id == peripheral.identifier || t.mac == mac {
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
            return
        }
        // DFU mode: scale reboots into its bootloader and advertises as
        // LsD…/LsDfu… (decompiled isUpgradeModelDevice) — connect on sight.
        if dfuScanActive, flow == .dfu, peripheral.state != .connected,
           let n = name, n.hasPrefix("LsD") {
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
            appendLog("update-mode scale found: \(n)")
            return
        }
        let entry = DiscoveredScale(id: peripheral.identifier, name: name ?? "Scale",
                                    mac: mac, rssi: RSSI.intValue)
        upsertScanEntry(entry)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        appendLog("GATT connected — discovering services")
        stage = .handshaking
        if flow == .dfu {
            dfuDrive(.connected)
            peripheral.discoverServices([cbuuid(DfuGATT.service)])
            return
        }
        peripheral.discoverServices([cbuuid(GATT.a6Service), cbuuid(GATT.deviceInfoService)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        stage = .failed("connect failed: \(error?.localizedDescription ?? "?")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        appendLog("link disconnected")
        guard !disconnectRequested else { return }
        if case .handshaking = stage {
            stage = .failed("disconnected during handshake")
        } else if stage == .connecting || stage == .scanning {
            stage = .failed("disconnected before handshake")
        } else if stage != .paired {
            stage = .idle
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ScaleCentral: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            stage = .failed("service discovery failed")
            return
        }
        for s in peripheral.services ?? [] {
            if flow == .dfu {
                peripheral.discoverCharacteristics(
                    [DfuGATT.controlPoint, DfuGATT.packet, DfuGATT.version].map(cbuuid),
                    for: s)
                continue
            }
            peripheral.discoverCharacteristics(
                [GATT.notifyData, GATT.notifyAck, GATT.writeData, GATT.writeAck,
                 GATTPlus.a6Broadcast, GATTPlus.otaData,
                 GATT.featureInfo, GATT.voltage,
                 GATTPlus.firmwareRevision, GATTPlus.hardwareRevision,
                 GATTPlus.modelNumber, GATTPlus.serialNumber, GATTPlus.manufacturerName].map(cbuuid),
                for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            stage = .failed("characteristic discovery failed")
            return
        }
        for c in service.characteristics ?? [] {
            chars[f(c.uuid)] = c
        }
        discoveredServices.insert(f(service.uuid))
        if flow == .dfu {
            dfuDrive(.servicesDiscovered)
            return
        }
        beginReadsIfNeeded()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            stage = .failed("notify enable failed (\(characteristic.uuid))")
            return
        }
        notifiesEnabled.insert(f(characteristic.uuid))
        if flow == .dfu {
            dfuDrive(.notifyEnabled(characteristic: f(characteristic.uuid)))
            return
        }
        tryStartMachine()
    }

    @objc(peripheral:didWriteValueForCharacteristic:error:)
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            appendLog("write NACK (\(shortName(f(characteristic.uuid)))): \(e.localizedDescription)")
        }
    }

    @objc(peripheral:didUpdateValueForCharacteristic:error:)
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let u = f(characteristic.uuid)
        // READ RESULTS ALSO LAND HERE (observed on iOS 26 — the fw value arrived
        // via didUpdateValueFor while didReadValueFor never fired, leaving
        // readResults empty and the XOR-variant fw stuck at the 1.5.0.0 default;
        // issue #8). Route pending-read values through the read pipeline first.
        if pendingReads.contains(u) {
            if error == nil, let v = characteristic.value {
                readResults[u] = v
            }
            pendingReads.removeAll { $0 == u }
            if !pendingReads.isEmpty, let c = chars[pendingReads[0]] {
                peripheral.readValue(for: c)
            } else {
                readsComplete = true
                tryStartMachine()
            }
            return
        }
        guard error == nil, let v = characteristic.value else { return }
        let hex = v.map { String(format: "%02X", $0) }.joined()
        appendLog("← \(shortName(u)) \(hex)")
        if flow == .dfu {
            dfuDrive(.notifyData(characteristic: u, data: [UInt8](v)))
            return
        }
        // A620/1531 frames are informational on this firmware; protocol lives on A621/A625.
        guard u == GATT.notifyData || u == GATT.notifyAck else { return }
        dispatch(.notifyData(characteristic: u, data: [UInt8](v)))
    }
}
