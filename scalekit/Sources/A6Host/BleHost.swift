import Foundation
import CoreBluetooth
import ScaleKit

// MARK: - Extra GATT UUIDs used by the host (standard 180a characteristics)

enum GATTPlus {
    // Captured from phone-B's fresh pairing (br8): the official app enables
    // FOUR notify channels — the challenge fired right after the 3rd CCCD
    // (A620's indication enable). We previously subscribed only A621+A625.
    static let a6Broadcast = UUID(uuidString: "0000A620-0000-1000-8000-00805F9B34FB")!  // 0x001b READ|INDICATE — pushes 100a broadcast-ID on connect
    static let otaData     = UUID(uuidString: "00001531-1212-EFDE-1523-785FEABCD123")!  // 0x002f WRITE|NOTIFY — OTA/data channel
    static let firmwareRevision = UUID(uuidString: "00002A26-0000-1000-8000-00805F9B34FB")!
    static let hardwareRevision = UUID(uuidString: "00002A27-0000-1000-8000-00805F9B34FB")!
    static let modelNumber      = UUID(uuidString: "00002A24-0000-1000-8000-00805F9B34FB")!
    static let serialNumber     = UUID(uuidString: "00002A25-0000-1000-8000-00805F9B34FB")!
    static let manufacturerName = UUID(uuidString: "00002A29-0000-1000-8000-00805F9B34FB")!
}

// MARK: - Output sink

protocol DriverOutput: AnyObject {
    func printLine(_ s: String)
}

// MARK: - Driver protocol (what differs between E1 pair and E2 session)

protocol ScaleDriver: AnyObject {
    /// Capture sink (reference semantics — host records reads directly).
    var recorder: CaptureRecorder { get }
    /// Host back-reference for the ACK watchdog.
    var host: BleHost? { get set }
    /// Characteristics to read after CCCDs are enabled (180a info + A641/A640).
    func readsAfterDiscovery() -> [UUID]
    /// Called once reads completed; construct + start the machine. `reads` carries
    /// every read response (A641 feature, A640 voltage, 180a strings) keyed by UUID.
    func startMachine(fw: String, reads: [UUID: Data])
    /// Single event entry point (notify data, timeouts). Returns actions to perform.
    func dispatch(_ event: LinkEvent) -> [LinkAction]
    /// Phase/status for periodic console output.
    var statusLine: String { get }
    /// Terminal state reached (success or defined failure) — CLI stops polling.
    var isFinished: Bool { get }
    /// Human-readable end-of-run summary.
    var summary: String { get }
}

// MARK: - BleHost (CoreBluetooth central + wire logging + watchdog)

final class BleHost: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    enum RunMode {
        case scan(TimeInterval)   // E0: advertise discovery only
        case run                  // E1/E2: connect and drive a machine
    }

    /// Scale MAC from advertisement manufacturer data (XOR key + capture meta).
    /// Updated at discovery time; drivers read it in startMachine.
    private(set) var mac: String
    let runMode: RunMode
    let out: DriverOutput

    var driver: ScaleDriver?
    /// Creates the driver once the scale's MAC is known (discovery time).
    var driverFactory: ((String) -> ScaleDriver?)?
    /// Called with a terminal reason (scan done, abort, clean disconnect request).
    var onDone: ((String) -> Void)?

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

    /// 3-second ACK watchdog (decompiled resend constant).
    private let timerQueue = DispatchQueue(label: "a6host.watchdog")
    private var watchdog: DispatchSourceTimer?

    init(mac: String, runMode: RunMode, out: DriverOutput) {
        self.mac = mac
        self.runMode = runMode
        self.out = out
        super.init()
    }

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func requestStop(reason: String) {
        if runCaseIsScan { central?.stopScan() }
        onDone?(reason)
    }

    private var runCaseIsScan: Bool {
        if case .scan = runMode { return true }
        return false
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            switch runMode {
            case .scan(let duration):
                out.printLine("BT powered on — scanning \(Int(duration))s for service A602 …")
                central.scanForPeripherals(
                    withServices: [cb(GATT.a6Service)],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                timerQueue.asyncAfter(deadline: .now() + duration) { [weak self] in
                    self?.onDone?("scan window elapsed")
                }
            case .run:
                connectOrScan()
            }
        case .poweredOff:
            onDone?("aborted: bluetooth off")
        case .unauthorized:
            onDone?("aborted: bluetooth unauthorized")
        case .unsupported:
            onDone?("aborted: bluetooth unsupported")
        default:
            out.printLine("BT state: \(central.state.rawValue) (waiting for poweredOn)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let mfgHex = mfg.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "-"

        switch runMode {
        case .scan:
            out.printLine(String(format: "[%3ds] %@ | id %@ | rssi %@ | mfg %@",
                                 Int(-Date().timeIntervalSince1970.rounded(.down)) * 0 + Int(Date().timeIntervalSince(ScanClock.start)),
                                 name ?? "?", peripheral.identifier.uuidString, RSSI, mfgHex))
            if let m = BleHost.macFromMfg(mfg) {
                ScanStore.save(identifier: peripheral.identifier.uuidString, mac: m, name: name)
            }
        case .run:
            guard self.peripheral == nil else { return }
            // An explicit --mac is authoritative (E1 found the advertised bytes are
            // the MAC in REVERSE; the ACK status XOR proves the true key starts 0xD8).
            if mac.isEmpty, let m = BleHost.macFromMfg(mfg) { mac = m }
            out.printLine("found \(name ?? "?") id=\(peripheral.identifier.uuidString) mac=\(mac) rssi=\(RSSI)")
            ScanStore.save(identifier: peripheral.identifier.uuidString, mac: mac, name: name)
            if driver == nil { driver = driverFactory?(mac) }
            guard driver != nil else {
                onDone?("aborted: no driver for this mode")
                return
            }
            central.stopScan()
            peripheral.delegate = self
            self.peripheral = peripheral
            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        out.printLine("GATT connected — discovering services …")
        peripheral.discoverServices([cb(GATT.a6Service), cb(GATT.deviceInfoService)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onDone?("aborted: connect failed (\(error?.localizedDescription ?? "?"))")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        out.printLine("link disconnected\(error.map { ": " + $0.localizedDescription } ?? "")")
        if disconnectRequested {
            onDone?("disconnected")
        } else if let d = driver, d.isFinished {
            onDone?("finished (link closed)")
        } else {
            onDone?("aborted: unexpected disconnect")
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            onDone?("aborted: service discovery failed")
            return
        }
        for s in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(
                [GATT.notifyData, GATT.notifyAck, GATT.writeData, GATT.writeAck,
                 GATTPlus.a6Broadcast, GATTPlus.otaData,
                 GATT.featureInfo, GATT.voltage,
                 GATTPlus.firmwareRevision, GATTPlus.hardwareRevision,
                 GATTPlus.modelNumber, GATTPlus.serialNumber, GATTPlus.manufacturerName].map(cb),
                for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            onDone?("aborted: characteristic discovery failed")
            return
        }
        for c in service.characteristics ?? [] {
            chars[f(c.uuid)] = c
            if f(c.uuid).uuidString.hasPrefix("0000A6") {
                var props: [String] = []
                if c.properties.contains(.read) { props.append("read") }
                if c.properties.contains(.write) { props.append("write") }
                if c.properties.contains(.writeWithoutResponse) { props.append("writeNR") }
                if c.properties.contains(.notify) { props.append("notify") }
                if c.properties.contains(.indicate) { props.append("indicate") }
                out.printLine("  char \(shortName(f(c.uuid))): {\(props.joined(separator: ","))}")
            }
        }
        discoveredServices.insert(f(service.uuid))

        // Decompiled order: READ_DEVICE_INFO → READ_FEATURE_INFO → SET_NOTIFY →
        // REQUEST_DEVICE_ID → WRITE_REGISTER. Reads come BEFORE CCCD enables.
        guard !readsStarted, peripheral.services?.count == discoveredServices.count else { return }
        beginReads()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            onDone?("aborted: CCCD enable failed (\(characteristic.uuid))")
            return
        }
        notifiesEnabled.insert(f(characteristic.uuid))
        tryStartMachine()
    }

    private func beginReads() {
        guard let d = driver else { return }
        let reads = d.readsAfterDiscovery().filter { chars[$0] != nil }
        guard !reads.isEmpty else {
            readsComplete = true   // route through tryStartMachine: it applies the fw default
            tryStartMachine()
            return
        }
        // Sequential reads: issuing several readValue calls back-to-back made
        // none of them complete on this firmware (observed live, 2026-09-21).
        out.printLine("reading \(reads.map(shortName).joined(separator: ", ")) (sequential) …")
        pendingReads = reads
        if let c = chars[reads[0]] { peripheral?.readValue(for: c) }
        // Failsafe: if reads never complete, continue after 5 s with what we have.
        timerQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.readsComplete, self.driver != nil else { return }
                self.out.printLine("⚠ read timeout (\(self.pendingReads.map(self.shortName).joined(separator: ", "))) — continuing with partial reads")
                self.pendingReads.removeAll()
                self.readsComplete = true
                self.tryStartMachine()
            }
        }
    }

    @objc(peripheral:didReadValueForCharacteristic:error:)
    func peripheral(_ peripheral: CBPeripheral, didReadValueFor characteristic: CBCharacteristic, error: Error?) {
        let u = f(characteristic.uuid)
        if let e = error {
            out.printLine("read \(shortName(u)) failed: \(e.localizedDescription)")
        } else if let v = characteristic.value {
            readResults[u] = v
            driver?.recorder.recordRead(characteristic: u, data: v)
            let text = String(data: v, encoding: .utf8).flatMap { $0.isEmpty ? nil : "\"\($0)\"" }
            out.printLine("read \(shortName(u)): \(v.map { String(format: "%02X", $0) }.joined())\(text.map { " \($0)" } ?? "")")
        }
        pendingReads.removeAll { $0 == u }
        // Fire the next read only after the previous one completed.
        if !pendingReads.isEmpty, let c = chars[pendingReads[0]] {
            peripheral.readValue(for: c)
        }
        if pendingReads.isEmpty {
            readsComplete = true
            tryStartMachine()
        }
    }

    private var machineStarted = false

    /// Machine starts only after the full decompiled pre-register sequence:
    /// discovery → reads (best effort) → CCCD enables → start. Re-entry points:
    /// read completion/failsafe and each didUpdateNotificationStateFor callback.
    private func tryStartMachine() {
        guard readsComplete, let d = driver, !machineStarted else { return }
        if !cccdStarted {
            cccdStarted = true
            // Official-app parity (btsnoop br8): subscribe ALL FOUR notifiable
            // channels — A620 (indicate) first, then A621/A625/1531.
            let wanted = [GATTPlus.a6Broadcast, GATT.notifyData, GATT.notifyAck, GATTPlus.otaData]
                .filter { chars[$0] != nil }
            out.printLine("enabling notifications on \(wanted.map(shortName).joined(separator: ", ")) …")
            for u in wanted {
                if let c = chars[u] { peripheral?.setNotifyValue(true, for: c) }
            }
            return   // didUpdateNotificationStateFor re-enters tryStartMachine
        }
        // Core pair must be on; A620/1531 are best-effort (phone subscribed
        // all four, but their absence shouldn't deadlock the machine).
        guard notifiesEnabled.contains(GATT.notifyData), notifiesEnabled.contains(GATT.notifyAck) else { return }
        machineStarted = true

        let fw = readResults[GATTPlus.firmwareRevision]
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        // This LS213-B unit is a current-generation device; when 180a reads are
        // unavailable, assume fw 1.5.0.0 (≥ 1.4.0.25 → XOR variant). E1 itself
        // verifies the assumption: the scale ACKs only correctly-encoded commands.
        let effectiveFw = fw.isEmpty ? "1.5.0.0" : fw
        if fw.isEmpty {
            d.recorder.notes += " · fw unread (reads stall), assumed 1.5.0.0 → XOR variant"
            out.printLine("⚠ fw unread — assuming 1.5.0.0 (XOR variant); E1 result will verify")
        }
        d.recorder.firmwareVersion = effectiveFw
        d.startMachine(fw: effectiveFw, reads: readResults)
    }

    @objc(peripheral:didWriteValueForCharacteristic:error:)
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            out.printLine("write NACK (\(shortName(f(characteristic.uuid)))): \(e.localizedDescription)")
        }
        // Success is silent — the wire line was already printed on write.
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let v = characteristic.value, let d = driver else { return }
        let u = f(characteristic.uuid)
        let hex = v.map { String(format: "%02X", $0) }.joined()
        out.printLine("← \(shortName(u)) \(hex)")
        d.recorder.record(characteristic: u, data: v)
        // A620/1531 frames are recorded for analysis but not dispatched — the
        // machines' protocol handlers only model A621/A625 traffic.
        guard u == GATT.notifyData || u == GATT.notifyAck else { return }
        let actions = d.dispatch(.notifyData(characteristic: u, data: [UInt8](v)))
        performAll(actions)
    }

    // MARK: Actions (all CB API calls stay on main)

    func performAll(_ actions: [LinkAction]) {
        for a in actions { perform(a) }
    }

    private func perform(_ action: LinkAction) {
        switch action {
        case .write(let uuid, let data):
            guard let c = chars[uuid] else {
                out.printLine("!! write to unknown characteristic \(uuid)")
                return
            }
            let hex = data.map { String(format: "%02X", $0) }.joined()
            // A624 on this unit rejects with-response writes ("Writing is not
            // permitted") — use the type the characteristic actually advertises.
            let withResponse = c.properties.contains(.write)
            out.printLine("→ write \(shortName(uuid)) \(hex)\(withResponse ? "" : " (no-response)")")
            peripheral?.writeValue(Data(data), for: c, type: withResponse ? .withResponse : .withoutResponse)
        case .disconnect:
            guard !disconnectRequested else { return }
            disconnectRequested = true
            out.printLine("→ disconnect (machine requested)")
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            // If the link never drops, still end the run after a grace period.
            timerQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.onDone != nil else { return }
                self.onDone?("finished (disconnect grace elapsed)")
                self.onDone = nil
            }
        default:
            break   // connect/discover/notify/read are driven by the host itself
        }
    }

    // MARK: Connect-or-scan (run mode)

    private func connectOrScan() {
        if let entry = ScanStore.last(),
           let u = UUID(uuidString: entry.identifier),
           let p = central.retrievePeripherals(withIdentifiers: [u]).first {
            if mac.isEmpty { mac = entry.mac }
            if driver == nil { driver = driverFactory?(mac) }
            guard driver != nil else {
                onDone?("aborted: no driver for this mode")
                return
            }
            out.printLine("retrieving persisted peripheral (\(entry.name ?? "?"), mac \(entry.mac)) …")
            peripheral = p
            p.delegate = self
            central.connect(p)
            return
        }
        out.printLine("no persisted peripheral — scanning for service A602 …")
        central.scanForPeripherals(withServices: [cb(GATT.a6Service)], options: nil)
    }

    // MARK: Watchdog (3 s ACK resend, driven by the driver via syncWatchdog)

    func armWatchdog() {
        timerQueue.sync { [weak self] in
            guard let self else { return }
            self.watchdog?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.timerQueue)
            t.schedule(deadline: .now() + 3.0)
            t.setEventHandler { [weak self] in
                // The machines are owned by the main thread (CB delegate queue = nil);
                // hop before touching driver state.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let d = self.driver else { return }
                    let actions = d.dispatch(.commandTimedOut)
                    self.performAll(actions)
                }
            }
            t.resume()
            self.watchdog = t
        }
    }

    func disarmWatchdog() {
        timerQueue.sync { [weak self] in
            self?.watchdog?.cancel()
            self?.watchdog = nil
        }
    }

    // MARK: Helpers

    /// CBUUID → Foundation UUID (16-bit forms expanded to the full base UUID).
    private func f(_ c: CBUUID) -> UUID {
        let s = c.uuidString.uppercased()
        if s.count == 4 {
            return UUID(uuidString: "0000\(s)-0000-1000-8000-00805F9B34FB")!
        }
        return UUID(uuidString: s) ?? UUID()
    }

    /// Foundation UUID → CBUUID.
    private func cb(_ u: UUID) -> CBUUID { CBUUID(nsuuid: u) }

    /// MAC from advertisement manufacturer data: trailing 6 bytes
    /// (TDD §6: `12 34 56 78 01 31 06 1b cb 0b d8`).
    static func macFromMfg(_ mfg: Data?) -> String? {
        guard let m = mfg, m.count >= 11 else { return nil }
        let bytes = m.suffix(6).map { String(format: "%02X", $0) }
        return bytes.joined(separator: ":")
    }

    func shortName(_ uuid: UUID) -> String {
        switch uuid {
        case GATT.notifyData: return "A621"
        case GATT.notifyAck: return "A625"
        case GATT.writeData: return "A624"
        case GATT.writeAck: return "A622"
        case GATTPlus.a6Broadcast: return "A620"
        case GATTPlus.otaData: return "1531"
        case GATT.featureInfo: return "A641"
        case GATT.voltage: return "A640"
        case GATTPlus.firmwareRevision: return "2A26"
        case GATTPlus.hardwareRevision: return "2A27"
        case GATTPlus.modelNumber: return "2A24"
        case GATTPlus.serialNumber: return "2A25"
        case GATTPlus.manufacturerName: return "2A29"
        default: return uuid.uuidString
        }
    }
}

/// Monotonic clock anchor for scan timestamps.
enum ScanClock {
    static let start = Date()
}

/// Persists the CBPeripheral.identifier ↔ MAC binding from `scan` runs so later
/// pair/session runs can `retrievePeripherals(withIdentifiers:)` directly.
enum ScanStore {
    struct Entry: Codable {
        var identifier: String
        var mac: String
        var name: String?
        var savedAt: Date?
    }

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("a6host", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scanstore.json")
    }

    static func last() -> Entry? {
        guard let d = try? Data(contentsOf: fileURL),
              let e = try? JSONDecoder().decode(Entry.self, from: d) else { return nil }
        return e
    }

    static func save(identifier: String, mac: String, name: String?) {
        let e = Entry(identifier: identifier, mac: mac, name: name, savedAt: Date())
        if let d = try? JSONEncoder().encode(e) {
            try? d.write(to: fileURL, options: .atomic)
        }
    }
}
