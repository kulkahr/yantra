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
    @Published private(set) var hrSamples: [KahaProtocol.HRSample] = []
    @Published private(set) var hrDay: Int = 0
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
    private var firmwareReadPending = false
    private var handshakeDone = false
    private var scanTimeout: DispatchWorkItem?
    /// Peripheral id being paired (persisted into DeviceStore by the hub).
    private var pendingPair: UUID?

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
        let t = DispatchWorkItem { [weak self] in
            guard let self, self.stage == .scanning else { return }
            self.central.stopScan()
            self.stage = .idle
            self.appendLog("scan timed out (30 s)")
        }
        scanTimeout = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: t)
        // Nordic UART service filter — Storm Call 3 exposes it.
        central.scanForPeripherals(withServices: [cb(KahaProtocol.GATT.uartService)], options: nil)
    }

    func stopScan() {
        scanTimeout?.cancel()
        scanTimeout = nil
        central.stopScan()
        if stage == .scanning { stage = .idle }
    }

    /// Pair: connect + handshake. The hub persists the inventory row
    /// (DeviceStore) — this only manages the link.
    func pair(_ watch: DiscoveredWatch) {
        pendingPair = watch.id
        resetLink()
        if let p = central.retrievePeripherals(withIdentifiers: [watch.id]).first {
            peripheral = p
            p.delegate = self
            central.connect(p)
            stage = .connecting
        } else {
            stage = .failed("watch out of range — rescan")
        }
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        handshakeDone = false
        stage = .idle
    }

    // MARK: - History (SRD-010 §5 acceptance 3)

    /// Requests one day of HR/BP history (day = 0 → today). Samples land in
    /// `hrSamples`; the watch UI renders them as a timeline. The interval
    /// command doubles as the auto-measure enabler (Crest parity, 60 min).
    func loadHRHistory(day: Int) {
        hrDay = day
        hrSamples = []
        send(KahaProtocol.setAutoHRInterval(minutes: 60))
        send(KahaProtocol.requestHRHistory(day: day, startHour: 0, endHour: 23))
        appendLog("HR history requested (day \(day))")
    }

    // MARK: - Internals

    /// ScaleKit UUIDs are pure Foundation; CoreBluetooth wants CBUUID.
    private func cb(_ u: UUID) -> CBUUID { CBUUID(string: u.uuidString) }

    private func resetLink() {
        chars = [:]
        subscribed = []
        firmwareReadPending = false
        handshakeDone = false
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
        // Info request burst — responses arrive as frames on the UART notify char.
        send(KahaProtocol.infoFrame(cmdId: KahaProtocol.InfoCmd.getDeviceName))
        send(KahaProtocol.infoFrame(cmdId: KahaProtocol.InfoCmd.getFirmwareVersion))
        send(KahaProtocol.infoFrame(cmdId: KahaProtocol.InfoCmd.getDeviceTime))
        send(KahaProtocol.infoFrame(cmdId: KahaProtocol.InfoCmd.getBatteryLevel))
        // 24-hour format (harmless personalization, Crest parity).
        send(KahaProtocol.frame(classId: KahaProtocol.ClassId.info,
                                cmdId: KahaProtocol.InfoCmd.set24HourFormat,
                                payload: [0x00]))
        // Resync the watch clock to the phone.
        send(KahaProtocol.setDeviceTime(from: Date()))
        handshakeDone = true
        stage = .live
        appendLog("watch live — awaiting pushes")
    }

    private func handleFrame(_ frame: KahaProtocol.Frame) {
        switch (frame.classId, frame.cmdId) {
        case (KahaProtocol.ClassId.live, KahaProtocol.LiveCmd.liveHealth):
            if let h = KahaProtocol.decodeLiveHealth(frame.payload) {
                liveHealth = h
                appendLog("live HR \(h.heartRate) bpm · BP \(h.systolic)/\(h.diastolic) · stress \(h.stress)")
            }
        case (KahaProtocol.ClassId.live, KahaProtocol.LiveCmd.liveSteps):
            if let s = KahaProtocol.decodeLiveSteps(frame.payload) {
                liveSteps = s
                appendLog("live steps \(s.steps)")
            }
        case (KahaProtocol.ClassId.fitness, KahaProtocol.FitnessCmd.hrBpInterval):
            // History day response — samples are 4-byte HR/BP records.
            hrSamples = KahaProtocol.decodeHRHistory(frame.payload, intervalMinutes: 60,
                                                     startHour: 0, day: hrDay)
                .map { $0.sample }
            appendLog("HR history: \(hrSamples.count) samples")
        default:
            handleInfoResponse(frame)
        }
    }

    private func handleInfoResponse(_ frame: KahaProtocol.Frame) {
        guard frame.classId == KahaProtocol.ClassId.info else { return }
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

    private func appendLog(_ s: String) {
        log.append(s)
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }
}

// MARK: - CBCentralManagerDelegate

extension WatchCentral: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn, stage == .scanning else { return }
        central.scanForPeripherals(withServices: [cb(KahaProtocol.GATT.uartService)], options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard stage == .scanning else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        guard let n = name, n.lowercased().contains("stormcall") else { return }
        let entry = DiscoveredWatch(id: peripheral.identifier, name: n, rssi: RSSI.intValue)
        if !foundWatches.contains(entry) { foundWatches.append(entry) }
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
        guard error == nil else {
            stage = .failed("service discovery failed")
            return
        }
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
        }
        // Standard firmware read (0x2A26) once discovery settles — the UART
        // burst fires when both CCCDs confirm (didUpdateNotificationStateFor).
        if chars[cb(KahaProtocol.GATT.uartRead)] != nil,
           chars[cb(KahaProtocol.GATT.batteryLevel)] != nil,
           !firmwareReadPending, !handshakeDone {
            firmwareReadPending = true
            if let fw = chars[cb(KahaProtocol.GATT.firmwareRevision)] {
                peripheral.readValue(for: fw)
            } else {
                requestInfo()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            appendLog("✗ subscribe failed: \(characteristic.uuid)")
            return
        }
        appendLog("notify on \(characteristic.uuid.uuidString.prefix(8))")
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
        if let frame = KahaProtocol.parse([UInt8](v)) {
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
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
}
