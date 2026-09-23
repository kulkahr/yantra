import XCTest
@testable import ScaleKit

final class DfuTests: XCTestCase {

    // MARK: Container parsing

    /// Builds a minimal but structurally valid OTA container with one BLE bin.
    /// Content sits at offset 128, immediately after the 128-byte header/descriptor block.
    func makeContainer(binSize: Int = 50, address: Int = 128) -> [UInt8] {
        var file: [UInt8] = Array(repeating: 0, count: 128 + binSize)
        func put(_ s: String, at o: Int) {
            for (i, b) in Array(s.utf8.prefix(16)).enumerated() { file[o + i] = b }
        }
        func putBE(_ v: Int, at o: Int) {
            file[o] = UInt8(truncatingIfNeeded: v >> 24)
            file[o + 1] = UInt8(truncatingIfNeeded: v >> 16)
            file[o + 2] = UInt8(truncatingIfNeeded: v >> 8)
            file[o + 3] = UInt8(truncatingIfNeeded: v)
        }
        put("LSOTA", at: 0)                 // magic (first 4 bytes: "LSOT")
        put("0006", at: 4)                  // container version
        putBE(binSize + 4, at: 8)           // payload size
        putBE(1_700_000_000, at: 12)        // createUtc
        put("0123456789abcdef", at: 16)     // md5
        // BLE descriptor at 32: version "0102", size, address, crc16 0xBEEF, md5
        put("0102", at: 32)
        putBE(binSize, at: 36)
        putBE(address, at: 40)
        putBE(0xBEEF, at: 44)
        put("fedcba9876543210", at: 48)
        // Content: recognizable bytes.
        for i in 0..<binSize { file[address + i] = UInt8(i & 0xFF) }
        return file
    }

    func testParseContainerSingleBin() throws {
        let img = try DfuImage.parse(makeContainer())
        XCTAssertEqual(img.magic, "LSOT")
        XCTAssertEqual(img.version, "0006")
        XCTAssertEqual(img.bins.count, 1)
        let bin = img.bins[0]
        XCTAssertEqual(bin.type, .ble)
        XCTAssertEqual(bin.version, "0102")
        XCTAssertEqual(bin.size, 50)
        XCTAssertEqual(bin.address, 128)
        XCTAssertEqual(bin.crc16, 0xBEEF)
        // Content 50 bytes + 4-byte LE CRC = 54 → packets 20+20+14.
        XCTAssertEqual(bin.packets.count, 3)
        XCTAssertEqual(bin.packets[0].count, 20)
        XCTAssertEqual(bin.packets[2].count, 14)
        XCTAssertEqual(bin.packets[0][0], 0x00)
        // CRC little-endian appended at the end of the last packet.
        let last = bin.packets[2]
        XCTAssertEqual(last[last.count - 4], 0xEF)
        XCTAssertEqual(last[last.count - 3], 0xBE)
        XCTAssertEqual(img.allBinSize, 54)
    }

    func testParseRejectsGarbage() {
        XCTAssertThrowsError(try DfuImage.parse([]))
        XCTAssertThrowsError(try DfuImage.parse([UInt8](repeating: 0xFF, count: 200)))
    }

    // MARK: State machine

    func makeMachine(binSize: Int = 80) -> (DfuStateMachine, DfuImage) {
        let img = try! DfuImage.parse(makeContainer(binSize: binSize))
        let m = DfuStateMachine(image: img, checkModel: "LS213-B")
        return (m, img)
    }

    /// Drives the machine from `start()` into the streaming phase, returning
    /// the output that emitted the first packet window.
    func driveToStreaming(_ m: inout DfuStateMachine) -> DfuStateMachine.Output {
        _ = m.start()
        _ = m.handle(.connected)
        _ = m.handle(.servicesDiscovered)
        _ = m.handle(.notifyEnabled(characteristic: DfuGATT.controlPoint))
        for _ in 0..<3 {
            _ = m.handle(.notifyData(characteristic: DfuGATT.controlPoint, data: [0x10, 0x01, 0x01]))
        }
        return m.handle(.notifyData(characteristic: DfuGATT.controlPoint, data: [0x10, 0x01, 0x01]))
    }

    func testFullHappyPath() {
        let (m0, img) = makeMachine(binSize: 80)   // 84 bytes → 5 packets (single window)
        var m = m0
        var out = m.start()
        XCTAssertEqual(m.phase, .connecting)
        XCTAssertEqual(out.actions, [.connect(macOrIdentifier: "")])

        out = m.handle(.connected)
        XCTAssertEqual(out.actions, [.discoverServices])
        out = m.handle(.servicesDiscovered)
        XCTAssertEqual(out.actions, [.enableNotify(characteristic: DfuGATT.controlPoint)])

        // Notify enabled → START_DFU [0x01, 4] for the BLE bin.
        out = m.handle(.notifyEnabled(characteristic: DfuGATT.controlPoint))
        XCTAssertEqual(m.phase, .startDfu(.ble))
        XCTAssertEqual(out.actions.first,
                       .write(characteristic: DfuGATT.controlPoint, data: [0x01, 0x04]))

        // START acked → image info on 1532.
        out = m.handle(.notifyData(characteristic: DfuGATT.controlPoint, data: [0x10, 0x01, 0x01]))
        XCTAssertEqual(m.phase, .writingImageInfo(.ble))
        guard case .write(let c, let info)? = out.actions.first else {
            return XCTFail("expected image-info write, got \(out.actions)")
        }
        XCTAssertEqual(c, DfuGATT.packet)
        XCTAssertEqual(info.count, 4 + 4 + 4 + 2)   // size + model + version + crc16
        XCTAssertEqual(info[0], 80)                  // size LE
        XCTAssertEqual(info[info.count - 2], 0xEF)   // crc16 LE
        XCTAssertEqual(info[info.count - 1], 0xBE)

        // Image-info ack → INIT_DFU → RECEIVE_FIRMWARE → streaming.
        _ = m.handle(.notifyData(characteristic: DfuGATT.controlPoint, data: [0x10, 0x01, 0x01]))
        XCTAssertEqual(m.phase, .initDfu(.ble))
        _ = m.handle(.notifyData(characteristic: DfuGATT.controlPoint, data: [0x10, 0x01, 0x01]))
        XCTAssertEqual(m.phase, .receiveFirmware(.ble))
        out = m.handle(.notifyData(characteristic: DfuGATT.controlPoint, data: [0x10, 0x01, 0x01]))
        guard case .streaming(.ble, let sent, let total) = m.phase else {
            return XCTFail("expected streaming, got \(m.phase)")
        }
        XCTAssertEqual(sent, img.bins[0].packets.count)
        XCTAssertEqual(total, img.bins[0].packets.count)
        XCTAssertEqual(out.actions.count, img.bins[0].packets.count)
        XCTAssertTrue(out.actions.allSatisfy {
            if case .write(let chr, _) = $0 { return chr == DfuGATT.packet }
            return false
        })

        // Device acks receiving everything → VALIDATE.
        out = m.handle(.notifyData(characteristic: DfuGATT.controlPoint, data: [0x10, 0x03]))
        XCTAssertEqual(m.phase, .validate(.ble))
        XCTAssertEqual(out.actions.first,
                       .write(characteristic: DfuGATT.controlPoint, data: [0x04]))

        // Validate ack → ACTIVATE.
        out = m.handle(.notifyData(characteristic: DfuGATT.controlPoint, data: [0x10, 0x04]))
        XCTAssertEqual(m.phase, .activate(.ble))
        XCTAssertEqual(out.actions.first,
                       .write(characteristic: DfuGATT.controlPoint, data: [0x05]))

        // Activation ack → done.
        out = m.handle(.notifyData(characteristic: DfuGATT.controlPoint, data: [0x10, 0x04]))
        XCTAssertEqual(m.phase, .done)
        XCTAssertTrue(out.finished)
        XCTAssertEqual(m.progress.percent, 100)
    }

    func testFlowControlPausesWindow() {
        let (m0, _) = makeMachine(binSize: 200)   // 204 bytes → 11 packets
        var m = m0
        let out = driveToStreaming(&m)
        guard case .streaming(_, let sent, let total) = m.phase else {
            return XCTFail("expected streaming, got \(m.phase)")
        }
        XCTAssertEqual(sent, 6, "exactly one flow-control window")
        XCTAssertEqual(total, 11)
        XCTAssertEqual(out.actions.count, 6)

        // Flow-resume unlocks the remaining frames.
        let out2 = m.handle(.notifyData(characteristic: DfuGATT.controlPoint, data: [0x11]))
        XCTAssertEqual(out2.actions.count, 5)
        guard case .streaming(_, let sent2, _) = m.phase else { return XCTFail() }
        XCTAssertEqual(sent2, 11)

        // A second resume while not paused is ignored (no actions).
        let out3 = m.handle(.notifyData(characteristic: DfuGATT.controlPoint, data: [0x11]))
        XCTAssertTrue(out3.actions.isEmpty)
    }

    func testUnexpectedNotificationFails() {
        let (m0, _) = makeMachine()
        var m = m0
        _ = m.start()
        _ = m.handle(.connected)
        _ = m.handle(.servicesDiscovered)
        _ = m.handle(.notifyEnabled(characteristic: DfuGATT.controlPoint))
        _ = m.handle(.notifyData(characteristic: DfuGATT.controlPoint, data: [0x10, 0x01, 0x01]))
        _ = m.handle(.notifyData(characteristic: DfuGATT.controlPoint, data: [0x21, 0x99]))
        guard case .failed = m.phase else { return XCTFail("expected failure, got \(m.phase)") }
    }

    func testDisconnectOutsideReconnectFails() {
        let (m0, _) = makeMachine()
        var m = m0
        _ = m.start()
        _ = m.handle(.connected)
        _ = m.handle(.disconnected)
        guard case .failed = m.phase else { return XCTFail("expected failure") }
    }
}
