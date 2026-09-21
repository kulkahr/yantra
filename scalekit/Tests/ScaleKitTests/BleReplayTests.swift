import XCTest
@testable import ScaleKit

/// Phase 0 leftover: replay the state machines on *recorded* notify sequences.
///
/// The `DeviceSimulator` tests replay traffic our own understanding generated —
/// they would pass even if a wire assumption were wrong. This suite replays
/// captures verbatim (see `analysis/captures/README.md`), so a wrong assumption
/// fails loudly. Until experiment E1/E2 records real hardware traffic, the
/// reference capture is explicitly labeled SYNTHETIC and only proves the harness.
final class BleReplayTests: XCTestCase {

    static let MAC = "31:06:1B:CB:0B:D8"
    static let DEVICE_ID = "9BBDD716E527"

    private func sessionConfig() -> SessionStateMachine.Config {
        SessionStateMachine.Config(
            mac: Self.MAC, firmwareVersion: "1.5.0.0", deviceId: Self.DEVICE_ID,
            slot: 1, unit: .kg, profile: SessionStateMachine.UserProfile(
                sexMale: true, age: 33, heightMeters: 1.75),
            utcProvider: { 1_758_432_000 },
            timeZoneHex: { 0x2A },
            dateProvider: { (2025, 9, 21, 10, 40, 0) })
    }

    // MARK: - Capture loading

    func testLoadSyntheticCapture() throws {
        let c = try BleReplayPlayer.load(resource: "synthetic_session_capture")
        XCTAssertEqual(c.meta.kind, .session)
        XCTAssertEqual(c.events.count, 6)
        // ACK notify: [00 01 30] — status 0x30 = 0x01 ^ MAC[0] (0x31), as the wire carries it
        XCTAssertEqual(c.events[1].data, A6Hex.decode("000130"))
        XCTAssertEqual(c.events[1].characteristic, GATT.notifyAck)
    }

    func testLoadRejectsMalformedCaptures() {
        XCTAssertThrowsError(try BleReplayPlayer.load(data: Data("{}".utf8)))
        XCTAssertThrowsError(try BleReplayPlayer.load(data: Data(
            #"[{"meta":{},"events":[]}]"#.utf8)))
        XCTAssertThrowsError(try BleReplayPlayer.load(data: Data(
            #"{"meta":{"kind":"session"},"events":[{"char":"A621","hex":"0"}]}"#.utf8)))
    }

    // MARK: - Session replay

    func testSyntheticSessionReplayReachesLiveWithRecord() throws {
        let capture = try BleReplayPlayer.load(resource: "synthetic_session_capture")
        let (machine, transcript) = try BleReplayPlayer.replaySession(capture, config: sessionConfig())

        // init → config flush (4 ACKs) → live, final record parsed
        XCTAssertEqual(machine.phase, .live)
        XCTAssertEqual(machine.remainingOnScale, 0)
        XCTAssertEqual(machine.lastRecord?.weightKg ?? 0, 72.85, accuracy: 0.0001)

        // Writes the host would have issued, in order: the data-ACK to A622 for
        // the 0x0009 init request, then the 0x000A init response to A624 (whose
        // ACK pops the queue and writes pushTime), then the data-ACK for the
        // final 0x4802 record.
        let codec = A6FrameCodec()
        var commands: [UInt16] = []
        for case .write(let char, let data) in transcript.writes {
            if char == GATT.writeData {
                let len = Int(data[1])
                let fr = try XCTUnwrap(codec.decodeFrame(Array(data[0..<(2 + len)]),
                                                       mac: Self.MAC, xored: true))
                commands.append(UInt16(fr.payload[0]) << 8 | UInt16(fr.payload[1]))
            }
        }
        // Single-flight drain: init response first, then each config push is
        // written the moment its predecessor's ACK pops it (4 ACK events).
        XCTAssertEqual(commands, [A6Command.responseInit.rawValue,
                                  A6Command.pushTime.rawValue,
                                  A6Command.pushUserInfo.rawValue,
                                  A6Command.pushUnit.rawValue])

        let ackCount = transcript.writes.filter {
            if case .write(let c, _) = $0 { return c == GATT.writeAck } else { return false }
        }.count
        XCTAssertEqual(ackCount, 2, "data-ACK to A622 for 0x0009 and for the 0x4802 record")

        XCTAssertFalse(transcript.disconnectRequested)
    }

    // MARK: - Pair replay (proves the pair path is harness-ready for E1)

    func testSyntheticPairReplayHappyPath() throws {
        // A minimal pair-shaped capture: register-ACK, register-result,
        // challenge, auth-ACK, bindNotice-ACK, bindResult — wire-encoded like the
        // DeviceSimulator emits them (XOR + plaintext-CRC convention).
        let sim = DeviceSimulator(mac: Self.MAC)
        var events: [[String: String]] = []
        func add(_ frames: [[UInt8]], from t: Double) {
            for (i, f) in frames.enumerated() {
                events.append(["t": String(format: "%.3f", t + Double(i) * 0.03),
                               "char": "A621",
                               "hex": f.hex])
            }
        }
        func addAck(_ t: Double) {
            events.append(["t": String(format: "%.3f", t),
                           "char": "A625",
                           "hex": sim.ackData().hex])
        }

        addAck(0.50)
        add(sim.command(0x0002, body: [0x01]), from: 0.55)
        add(sim.command(0x0007, body: A6Hex.decode("AABBCCDDEEFF")), from: 0.70)
        addAck(0.85)
        addAck(1.10)
        add(sim.command(0x0004, body: [0x01]), from: 1.15)

        var obj: [String: Any] = [
            "version": 1,
            "meta": ["mac": Self.MAC, "firmwareVersion": "1.5.0.0",
                     "kind": "pair", "recordedAt": "2026-09-21T08:00:00Z",
                     "notes": "SYNTHETIC pair-flow proof for the harness"],
            "events": events,
        ]
        let data = try JSONSerialization.data(withJSONObject: obj)
        let capture = try BleReplayPlayer.load(data: data)
        XCTAssertEqual(capture.meta.kind, .pair)

        let (machine, transcript) = try BleReplayPlayer.replayPair(
            capture,
            config: PairStateMachine.Config(mac: Self.MAC, firmwareVersion: "1.5.0.0"),
            deviceIdInput: A6Obfuscation.macHex(Self.MAC),
            bindConfirm: true)

        _ = machine  // phase asserted below via returned machine
        XCTAssertEqual(machine.phase, .done)
        XCTAssertFalse(transcript.writes.isEmpty)

        // The auth response 0x0008 must have been written to A624 after the challenge.
        let codec = A6FrameCodec()
        var wroteAuth = false
        for case .write(let char, let data) in transcript.writes where char == GATT.writeData {
            let len = Int(data[1])
            if let fr = codec.decodeFrame(Array(data[0..<(2 + len)]), mac: Self.MAC, xored: true),
               fr.payload.count >= 2,
               UInt16(fr.payload[0]) << 8 | UInt16(fr.payload[1]) == A6Command.auth.rawValue {
                wroteAuth = true
            }
        }
        XCTAssertTrue(wroteAuth, "auth response 0x0008 must be written after the 0x0007 challenge")
        XCTAssertTrue(transcript.disconnectRequested, "successful bind ends with a polite disconnect")
    }

    func testSyntheticPairReplayRegisterRejected() throws {
        let sim = DeviceSimulator(mac: Self.MAC)
        var events: [[String: String]] = []
        events.append(["t": "0.50", "char": "A625", "hex": sim.ackData().hex])
        for f in sim.command(0x0002, body: [0x02]) {
            events.append(["t": "0.55", "char": "A621", "hex": f.hex])
        }
        let obj: [String: Any] = [
            "version": 1,
            "meta": ["mac": Self.MAC, "firmwareVersion": "1.5.0.0", "kind": "pair"],
            "events": events,
        ]
        let capture = try BleReplayPlayer.load(data: try JSONSerialization.data(withJSONObject: obj))
        let (machine, transcript) = try BleReplayPlayer.replayPair(
            capture,
            config: PairStateMachine.Config(mac: Self.MAC, firmwareVersion: "1.5.0.0"),
            deviceIdInput: A6Obfuscation.macHex(Self.MAC),
            bindConfirm: true)
        XCTAssertEqual(machine.phase, .failed(.registerRejected))
        XCTAssertTrue(transcript.disconnectRequested)
    }
}

private extension Array where Element == UInt8 {
    var hex: String { A6Hex.encode(self) }
}
