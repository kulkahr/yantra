import XCTest
@testable import Firefly
import ScaleKit

final class ModelTests: XCTestCase {

    func testStoreDedupByDeviceTimeWeight() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("firefly-test-\(UUID().uuidString)", isDirectory: true)
        let store = MeasurementStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dev = "d80bcb1b0631"
        let t = Date(timeIntervalSince1970: 1_789_975_959)
        var payload: [UInt8] = [0x48, 0x02, 0x00, 0x00,   // header
                                0x00, 0x00, 0x00, 0x00,   // remain + flags(0)
                                0x1B, 0xA3]               // 70.75 kg
        let rec = A6WeightRecordParser.parse(payload)!
        let a = MeasurementRecord(deviceId: dev, slot: 1, from: rec)
        XCTAssertTrue(store.insert(a))
        XCTAssertFalse(store.insert(a), "exact duplicate must be rejected")

        var rec2 = rec
        rec2.utc = Int(t.timeIntervalSince1970) + 5   // different measurement time
        let b = MeasurementRecord(deviceId: dev, slot: 1, from: rec2)
        XCTAssertTrue(store.insert(b), "different UTC is a new record")
    }

    func testCSVExport() {
        let dev = "d80bcb1b0631"
        var payload: [UInt8] = [0x48, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1B, 0xA3]
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])   // dummy UTC
        let rec = A6WeightRecordParser.parse(payload)!
        let m = MeasurementRecord(deviceId: dev, slot: 1, from: rec)
        let csv = CSVExporter.export(records: [m])
        XCTAssertTrue(csv.hasPrefix("utc,weight_kg,impedance_ohm,device_id,slot\n"))
        XCTAssertTrue(csv.contains("70.75"))
        XCTAssertTrue(csv.contains(dev))
    }

    func testMacFromMfgReversed() {
        // Advertised: 12345678 01 31 06 1b cb 0b d8 → MAC D8:0B:CB:1B:06:31
        let mfg = Data([0x12, 0x34, 0x56, 0x78, 0x01, 0x31, 0x06, 0x1b, 0xcb, 0x0b, 0xd8])
        XCTAssertEqual(ScaleCentral.macFromMfg(mfg), "D8:0B:CB:1B:06:31")
        XCTAssertNil(ScaleCentral.macFromMfg(nil))
        XCTAssertNil(ScaleCentral.macFromMfg(Data([1, 2])))
    }
}
