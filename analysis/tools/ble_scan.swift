import Foundation
import CoreBluetooth

// Scan for Lifesense "A6" service (realme Smart Scale / LS213-B) and dump raw ad data.
let a6 = CBUUID(string: "A602")

class Scanner: NSObject, CBCentralManagerDelegate {
    var done = false
    lazy var cm = CBCentralManager(delegate: self, queue: nil)
    let start = Date()

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            fputs("BT powered on, scanning for service A602...\n", stdout); fflush(stdout)
            cm.scanForPeripherals(withServices: [a6],
                                  options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        default:
            fputs("BT state: \(central.state.rawValue) (5=poweredOn)\n", stdout); fflush(stdout)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? (advertisementData[CBAdvertisementDataManufacturerDataKey] == nil ? peripheral.name ?? "?" : "?")
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let mfgHex = mfg.map { $0.map { String(format: "%02x", $0) }.joined() } ?? "-"
        let elapsed = Int(Date().timeIntervalSince(start))
        print("[\(elapsed)s] \(name) | \(peripheral.identifier.uuidString) | RSSI \(RSSI) | svc \(services.map{ $0.uuidString }) | mfg \(mfgHex)")
        fflush(stdout)
    }
}

let s = Scanner()
_ = s.cm
let deadline = Date().addingTimeInterval(60)
RunLoop.main.run(until: deadline)
print("SCAN_DONE")
