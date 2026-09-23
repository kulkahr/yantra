import XCTest
@testable import Firefly
import ScaleKit

final class ModelTests: XCTestCase {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("firefly-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func payload(weightKg: Double = 70.75) -> [UInt8] {
        var p: [UInt8] = [0x48, 0x02, 0x00, 0x00,   // header
                          0x00, 0x00, 0x00, 0x00,   // remain + flags(0)
                          0x1B, 0xA3]               // weight×100
        p.append(contentsOf: [0x00, 0x00, 0x00, 0x00])   // dummy UTC
        return p
    }

    private func makeRecord(deviceId: String = "d80bcb1b0631",
                            personId: UUID? = nil) -> MeasurementRecord {
        MeasurementRecord(deviceId: deviceId, slot: 1, personId: personId,
                          from: A6WeightRecordParser.parse(payload())!)
    }

    func testStoreDedupByDeviceTimeWeight() {
        let dir = tempDir()
        let store = MeasurementStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dev = "d80bcb1b0631"
        let t = Date(timeIntervalSince1970: 1_789_975_959)
        var rec = A6WeightRecordParser.parse(payload())!
        rec.utc = Int(t.timeIntervalSince1970)
        let a = MeasurementRecord(deviceId: dev, slot: 1, from: rec)
        XCTAssertTrue(store.insert(a))
        XCTAssertFalse(store.insert(a), "exact duplicate must be rejected")

        var rec2 = rec
        rec2.utc = Int(t.timeIntervalSince1970) + 5   // different measurement time
        let b = MeasurementRecord(deviceId: dev, slot: 1, from: rec2)
        XCTAssertTrue(store.insert(b), "different UTC is a new record")
    }

    func testPersonAssignmentRoundTrip() {
        let dir = tempDir()
        let store = MeasurementStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let alice = UUID()
        let rec = makeRecord(personId: nil)
        XCTAssertTrue(store.insert(rec))
        XCTAssertTrue(store.unassignedCount() == 1)

        var assigned = rec
        assigned.personId = alice
        XCTAssertTrue(store.update(assigned), "update must find the record by id")

        XCTAssertEqual(store.loadAll().first?.personId, alice)
        XCTAssertEqual(store.unassignedCount(), 0)
    }

    func testUpdateMissingRecordReturnsFalse() {
        let dir = tempDir()
        let store = MeasurementStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        var rec = makeRecord()
        rec.id = UUID()
        XCTAssertFalse(store.update(rec), "no record with that id yet")
        XCTAssertTrue(store.insert(rec))
        XCTAssertTrue(store.update(rec), "now it exists")
    }

    func testPersonStoreSlotsAndActive() {
        let dir = tempDir()
        let store = PersonStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = store.add(name: "Alice")
        XCTAssertEqual(a?.slot, 1, "first person claims slot 1")
        let b = store.add(name: "Bob", preferredSlot: 3)
        XCTAssertEqual(b?.slot, 3)
        // A taken preferred slot falls back to the lowest free slot (documented).
        let c = store.add(name: "Cain", preferredSlot: 3)
        XCTAssertEqual(c?.slot, 2, "taken preferred slot falls back to next free")
        XCTAssertNil(store.person(inSlot: 4))
        XCTAssertEqual(store.person(inSlot: 3)?.name, "Bob")

        // Active person defaults to the first added.
        XCTAssertEqual(store.activePersonId, a?.id)

        store.setActive(b!)
        XCTAssertEqual(store.activePerson?.name, "Bob")

        // Removing the active person clears the active pointer.
        store.remove(b!)
        XCTAssertNil(store.activePersonId)
        XCTAssertNil(store.person(inSlot: 3), "slot freed on remove")

        // Five-person scale limit: Bob's removal freed slot 3 → 3, 4, 5 free.
        XCTAssertEqual(store.add(name: "D")?.slot, 3)
        XCTAssertEqual(store.add(name: "E")?.slot, 4)
        XCTAssertEqual(store.add(name: "F")?.slot, 5)
        XCTAssertNil(store.add(name: "G"), "no free slot left")
        XCTAssertNil(store.add(name: "H", preferredSlot: 9), "out-of-range slot rejected")
    }

    func testPersonStorePersists() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PersonStore(directory: dir)
        _ = store.add(name: "Alice", preferredSlot: 2)

        let reloaded = PersonStore(directory: dir)
        XCTAssertEqual(reloaded.people.count, 1)
        XCTAssertEqual(reloaded.people.first?.name, "Alice")
        XCTAssertEqual(reloaded.people.first?.slot, 2)
        XCTAssertEqual(reloaded.activePerson?.name, "Alice", "active pointer restored")
    }

    func testCSVExportIncludesPerson() {
        let dev = "d80bcb1b0631"
        let personId = UUID()
        let m = makeRecord(deviceId: dev, personId: personId)
        var p = Person(name: "Alice", slot: 1)
        p.id = personId
        let csv = CSVExporter.export(records: [m], people: [p])
        XCTAssertTrue(csv.hasPrefix("utc,weight_kg,impedance_ohm,device_id,slot,person\n"))
        XCTAssertTrue(csv.contains("70.75"))
        XCTAssertTrue(csv.contains(dev))
        XCTAssertTrue(csv.contains("Alice"))
    }

    func testCSVExportNameCommaQuoting() {
        let personId = UUID()
        let m = makeRecord(personId: personId)
        var p = Person(name: "Doe, Jane", slot: 1)
        p.id = personId
        let csv = CSVExporter.export(records: [m], people: [p])
        XCTAssertTrue(csv.contains("\"Doe, Jane\""), "names with commas must be quoted")
    }

    func testMacFromMfgReversed() {
        // Advertised: 12345678 01 31 06 1b cb 0b d8 → MAC D8:0B:CB:1B:06:31
        let mfg = Data([0x12, 0x34, 0x56, 0x78, 0x01, 0x31, 0x06, 0x1b, 0xcb, 0x0b, 0xd8])
        XCTAssertEqual(ScaleCentral.macFromMfg(mfg), "D8:0B:CB:1B:06:31")
        XCTAssertNil(ScaleCentral.macFromMfg(nil))
        XCTAssertNil(ScaleCentral.macFromMfg(Data([1, 2])))
    }
}
