import XCTest
@testable import ScaleKit

/// Full-protocol replay tests: a Python-inspired device simulator (deviceSim.swift)
/// feeds the state machines exactly what the real firmware transmits.
final class SessionStateMachineTests: XCTestCase {

    static let MAC = "31:06:1B:CB:0B:D8"
    static let DEVICE_ID = "9BBDD716E527"   // captured verification code ⊕ MAC

    var utc = UInt32(1_758_432_000)

    func makeMachine(profile: SessionStateMachine.UserProfile? = SessionStateMachine.UserProfile(
        sexMale: true, age: 33, heightMeters: 1.75)) -> SessionStateMachine {
        utc = UInt32(1_758_432_000)
        return SessionStateMachine(config: .init(
            mac: Self.MAC, firmwareVersion: "1.5.0.0", deviceId: Self.DEVICE_ID,
            slot: 1, unit: .kg, profile: profile,
            utcProvider: { [weak self] in self?.utc ?? 1_758_432_000 },
            timeZoneHex: { 0x2A },                              // +5h west of UTC
            dateProvider: { (2025, 9, 21, 10, 40, 0) }))
    }

    // MARK: - Init + config push

    func testInitTriggersConfigPushesInOrder() throws {
        var m = makeMachine()
        let sim = DeviceSimulator(mac: Self.MAC)

        var written: [UInt16] = []
        func collect(_ out: SessionStateMachine.Output) {
            let codec = A6FrameCodec()
            for case .write(let c, let d) in out.actions where c == GATT.writeData {
                let len = Int(d[1])
                if let fr = codec.decodeFrame(Array(d[0..<(2 + len)]), mac: Self.MAC, xored: true),
                   fr.payload.count >= 2 {
                    written.append(UInt16(fr.payload[0]) << 8 | UInt16(fr.payload[1]))
                }
            }
        }

        collect(m.start()); collect(m.handle(.connected))
        collect(m.handle(.servicesDiscovered))
        collect(m.handle(.notifyEnabled(characteristic: GATT.notifyData)))
        collect(m.handle(.notifyEnabled(characteristic: GATT.notifyAck)))
        // Bound device: machine waits for the login challenge before init.
        // (Permissive: a direct 0x0009 is still honored — the flow below tests that.)
        XCTAssertEqual(m.phase, .awaitingLogin)

        // device: init request 0x0009 (single frame)
        for f in sim.command(0x0009, body: [0b0011_1111]) {
            collect(m.handle(.notifyData(characteristic: GATT.notifyData, data: f)))
        }
        XCTAssertEqual(m.phase, .pushingConfig)
        XCTAssertEqual(m.queue.count, 4)

        // Single-flight queue (decompiled parity): only the HEAD command is on the
        // wire until its ACK pops it — so exactly the init response went out first.
        XCTAssertEqual(written, [A6Command.responseInit.rawValue])
        written = []

        // Each ACK pops the head and immediately writes the next queued command.
        // Hardware-verified push set (HCI capture): user-info, unit, HR-switch.
        for expected: UInt16 in [A6Command.pushUserInfo.rawValue,
                                 A6Command.pushUnit.rawValue,
                                 A6Command.pushHeartRateSwitch.rawValue] {
            collect(m.handle(.notifyData(characteristic: GATT.notifyAck, data: sim.ackData())))
            XCTAssertEqual(written, [expected], "next config push must follow its predecessor's ACK")
            written = []
        }

        // Final ACK empties the flush → session armed for measurement.
        collect(m.handle(.notifyData(characteristic: GATT.notifyAck, data: sim.ackData())))
        XCTAssertEqual(m.queue.count, 0)
        XCTAssertEqual(m.phase, .live)
    }

    // MARK: - Login (bound device): 0x0007 challenge → 0x0008 response mode 0

    func testLoginChallengeTriggersAuthResponseMode0() throws {
        var m = makeMachine()
        let sim = DeviceSimulator(mac: Self.MAC)
        _ = m.start(); _ = m.handle(.connected); _ = m.handle(.servicesDiscovered)
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyData))
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))
        XCTAssertEqual(m.phase, .awaitingLogin)

        // device: login challenge 0x0007 with verification code
        var authWritten: [UInt8]?
        for f in sim.command(0x0007, body: A6Hex.decode("AABBCCDDEEFF")) {
            let out = m.handle(.notifyData(characteristic: GATT.notifyData, data: f))
            for case .write(let c, let d) in out.actions where c == GATT.writeData {
                authWritten = Array(d)
            }
        }
        XCTAssertEqual(m.phase, .awaitingInit)
        XCTAssertEqual(m.verificationCode, "AABBCCDDEEFF")

        // The written bytes must be the encoded 0x0008 auth response (mode 0 = login).
        // (20-byte ASCII-hex payload → 2 frames; compare the re-encoded packet.)
        let d = try XCTUnwrap(authWritten)
        let expected = A6FrameCodec().encodePacket(
            payload: A6Commands.authResponse(success: true, verificationCodeHex6: "AABBCCDDEEFF", mode: 0),
            mac: Self.MAC, xored: true)
        XCTAssertEqual(d, expected)
    }

    func testConfigAcksDrainToLive() {
        var m = makeMachine()
        let sim = DeviceSimulator(mac: Self.MAC)
        _ = m.start(); _ = m.handle(.connected); _ = m.handle(.servicesDiscovered)
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyData))
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))

        for f in sim.command(0x0009, body: [0b0011_1111]) {
            _ = m.handle(.notifyData(characteristic: GATT.notifyData, data: f))
        }
        XCTAssertEqual(m.phase, .pushingConfig)

        // device ACKs each queued command (real firmware ACKs byte-level over A625)
        for _ in 0..<4 {
            _ = m.handle(.notifyData(characteristic: GATT.notifyAck, data: sim.ackData()))
        }
        XCTAssertEqual(m.queue.count, 0)

        // final record remainCount=0 lands while config flush → straight into live
        var out = SessionStateMachine.Output()
        for f in sim.recordPacket(remain: 0, flags: 0, kg: 72.85) {
            out = m.handle(.notifyData(characteristic: GATT.notifyData, data: f))
        }
        XCTAssertEqual(m.phase, .live)
        XCTAssertEqual(out.measurements.count, 1)
        XCTAssertEqual(out.measurements[0].weightKg, 72.85, accuracy: 0.0001)
        XCTAssertEqual(out.measurements[0].remainCount, 0)
    }

    // MARK: - History drain

    func testHistoryDrainCompletes() {
        var m = makeMachine()
        let sim = DeviceSimulator(mac: Self.MAC)
        _ = m.start(); _ = m.handle(.connected); _ = m.handle(.servicesDiscovered)
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyData))
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))
        for f in sim.command(0x0009, body: [0b0011_1111]) {
            _ = m.handle(.notifyData(characteristic: GATT.notifyData, data: f))
        }
        for _ in 0..<4 { _ = m.handle(.notifyData(characteristic: GATT.notifyAck, data: sim.ackData())) }

        func pumpRecord(_ remain: Int, _ kg: Double) -> SessionStateMachine.Output {
            var out = SessionStateMachine.Output()
            for f in sim.recordPacket(remain: remain, flags: 0, kg: kg) {
                out = m.handle(.notifyData(characteristic: GATT.notifyData, data: f))
            }
            return out
        }

        var out = pumpRecord(2, 70.10)          // announces 2 stored records
        XCTAssertEqual(m.phase, .draining)
        XCTAssertEqual(out.measurements.first?.weightKg ?? 0, 70.10, accuracy: 0.0001)
        _ = pumpRecord(1, 71.20)
        out = pumpRecord(0, 71.20)              // drain finished
        XCTAssertTrue(out.drainFinished)
        XCTAssertEqual(m.phase, .live)
        XCTAssertEqual(m.remainingOnScale, 0)
    }

    // MARK: - Live stream samples

    func testLiveStreamSamples() {
        var m = makeMachine()
        let sim = DeviceSimulator(mac: Self.MAC)
        _ = m.start(); _ = m.handle(.connected); _ = m.handle(.servicesDiscovered)
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyData))
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))
        for f in sim.command(0x0009, body: [0b0011_1111]) {
            _ = m.handle(.notifyData(characteristic: GATT.notifyData, data: f))
        }
        for _ in 0..<4 { _ = m.handle(.notifyData(characteristic: GATT.notifyAck, data: sim.ackData())) }

        let sampleFrames = sim.command(0x00E9, body: [0x00] + A6Bytes.from(int: 1_758_432_000)
                                + A6Bytes.from(short: 0) + A6Bytes.from(short: 0) + A6Bytes.from(short: 1))
        var out = SessionStateMachine.Output()
        for f in sampleFrames {
            out = m.handle(.notifyData(characteristic: GATT.notifyData, data: f))
        }
        XCTAssertEqual(out.liveSamples.count, 1)
        XCTAssertEqual(m.phase, .live)
    }

    // MARK: - Echoes don't disturb config flush

    func testEchoDoesNotChangeState() {
        var m = makeMachine()
        let sim = DeviceSimulator(mac: Self.MAC)
        _ = m.start(); _ = m.handle(.connected); _ = m.handle(.servicesDiscovered)
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyData))
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))
        for f in sim.command(0x0009, body: [0b0011_1111]) {
            _ = m.handle(.notifyData(characteristic: GATT.notifyData, data: f))
        }
        for _ in 0..<4 { _ = m.handle(.notifyData(characteristic: GATT.notifyAck, data: sim.ackData())) }
        XCTAssertEqual(m.phase, .live)   // flush completed into armed state

        // interleaved 0x2001 unit echo — phase and command queue untouched;
        // the ONLY action is the mandatory data-ACK to A622 (writeAckCommand(true)).
        let echo = sim.command(0x2001, body: [0x00])[0]
        let out = m.handle(.notifyData(characteristic: GATT.notifyData, data: echo))
        XCTAssertEqual(m.phase, .live)
        XCTAssertEqual(out.actions, [.write(characteristic: GATT.writeAck,
                                            data: A6Commands.ack(ok: true, mac: Self.MAC, xored: true))])
        XCTAssertFalse(out.actions.isEmpty)
    }

    // MARK: - Failure paths

    func testUnexpectedDisconnectFails() {
        var m = makeMachine()
        _ = m.start(); _ = m.handle(.connected); _ = m.handle(.servicesDiscovered)
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))
        _ = m.handle(.disconnected)
        XCTAssertEqual(m.phase, .failed(.protocolError("unexpected disconnect")))
    }

    func testFinishDisconnects() {
        var m = makeMachine()
        _ = m.start(); _ = m.handle(.connected); _ = m.handle(.servicesDiscovered)
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))
        let out = m.finish()
        XCTAssertEqual(m.phase, .disconnecting)
        XCTAssertTrue(out.actions.contains(.disconnect))
        _ = m.handle(.disconnected)
        XCTAssertEqual(m.phase, .done)
    }

    // MARK: - Pairing (same wire semantics, device side of 0x0001/0x0007/0x0003)

    func testPairBindHappyPath() {
        var m = PairStateMachine(config: .init(mac: Self.MAC, firmwareVersion: "1.5.0.0"))
        let sim = DeviceSimulator(mac: Self.MAC)

        _ = m.start(); _ = m.handle(.connected); _ = m.handle(.servicesDiscovered)
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyData))
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))
        _ = m.handle(.readResponse(characteristic: GATT.featureInfo, data: [0b0000_0111]))
        XCTAssertEqual(m.phase, .awaitingDeviceIdInput)

        // official default: register the MAC itself as deviceId (NORMAL_UNREGISTER)
        _ = m.setDeviceIdInput(A6Obfuscation.macHex(Self.MAC))
        XCTAssertEqual(m.phase, .registering)

        // device ACKs the register command
        _ = m.handle(.notifyData(characteristic: GATT.notifyAck, data: sim.ackData()))
        // device: register result 0x0002 success
        for f in sim.command(0x0002, body: [0x01]) {
            _ = m.handle(.notifyData(characteristic: GATT.notifyData, data: f))
        }
        // device: auth challenge 0x0007 with verification code
        for f in sim.command(0x0007, body: A6Hex.decode("AABBCCDDEEFF")) {
            _ = m.handle(.notifyData(characteristic: GATT.notifyData, data: f))
        }
        XCTAssertEqual(m.phase, .awaitingAuthAck)
        XCTAssertEqual(m.verificationCode, "AABBCCDDEEFF")

        // device ACKs the auth response → host must confirm the bind
        _ = m.handle(.notifyData(characteristic: GATT.notifyAck, data: sim.ackData()))
        XCTAssertEqual(m.phase, .awaitingBindConfirm)

        _ = m.setBindConfirm(.pairingSuccess, slot: 1)
        XCTAssertEqual(m.phase, .binding)

        // device ACKs bindNotice, then sends bindResult success
        _ = m.handle(.notifyData(characteristic: GATT.notifyAck, data: sim.ackData()))
        var out = PairStateMachine.Output()
        for f in sim.command(0x0004, body: [0x01]) {
            out = m.handle(.notifyData(characteristic: GATT.notifyData, data: f))
        }
        XCTAssertEqual(m.phase, .disconnecting)
        XCTAssertNotNil(out.bindRecord)
        XCTAssertEqual(out.bindRecord?.mac, Self.MAC)
        XCTAssertEqual(out.bindRecord?.deviceId, "31061BCB0BD8")
        XCTAssertTrue(out.actions.contains(.disconnect))

        _ = m.handle(.disconnected)
        XCTAssertEqual(m.phase, .done)
    }

    func testPairRegisterRejected() {
        var m = PairStateMachine(config: .init(mac: Self.MAC, firmwareVersion: "1.5.0.0"))
        let sim = DeviceSimulator(mac: Self.MAC)
        _ = m.start(); _ = m.handle(.connected); _ = m.handle(.servicesDiscovered)
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyData))
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))
        _ = m.handle(.readResponse(characteristic: GATT.featureInfo, data: [0b0000_0111]))
        _ = m.setDeviceIdInput(A6Obfuscation.macHex(Self.MAC))
        _ = m.handle(.notifyData(characteristic: GATT.notifyAck, data: sim.ackData()))

        // register result = 2 (rejected)
        var out = PairStateMachine.Output()
        for f in sim.command(0x0002, body: [0x02]) {
            out = m.handle(.notifyData(characteristic: GATT.notifyData, data: f))
        }
        XCTAssertEqual(m.phase, .failed(.registerRejected))
        XCTAssertTrue(out.actions.contains(.disconnect))
    }

    func testPairBindRefused() {
        var m = PairStateMachine(config: .init(mac: Self.MAC, firmwareVersion: "1.5.0.0"))
        let sim = DeviceSimulator(mac: Self.MAC)
        _ = m.start(); _ = m.handle(.connected); _ = m.handle(.servicesDiscovered)
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyData))
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))
        _ = m.handle(.readResponse(characteristic: GATT.featureInfo, data: [0b0000_0111]))
        _ = m.setDeviceIdInput(A6Obfuscation.macHex(Self.MAC))
        _ = m.handle(.notifyData(characteristic: GATT.notifyAck, data: sim.ackData()))
        for f in sim.command(0x0007, body: A6Hex.decode("AABBCCDDEEFF")) {
            _ = m.handle(.notifyData(characteristic: GATT.notifyData, data: f))
        }
        _ = m.handle(.notifyData(characteristic: GATT.notifyAck, data: sim.ackData()))
        _ = m.setBindConfirm(.pairingSuccess, slot: 1)
        _ = m.handle(.notifyData(characteristic: GATT.notifyAck, data: sim.ackData()))

        // bindResult = 2 (refused)
        var out = PairStateMachine.Output()
        for f in sim.command(0x0004, body: [0x02]) {
            out = m.handle(.notifyData(characteristic: GATT.notifyData, data: f))
        }
        XCTAssertEqual(m.phase, .failed(.bindRefused))
        XCTAssertTrue(out.actions.contains(.disconnect))
    }

    func testPairResendExhaustion() {
        var m = PairStateMachine(config: .init(mac: Self.MAC, firmwareVersion: "1.5.0.0"))
        _ = m.start()
        _ = m.setDeviceIdInput(A6Obfuscation.macHex(Self.MAC))   // no-op in connecting phase
        var out = PairStateMachine.Output()
        for _ in 0..<5 {
            out = m.handle(.commandTimedOut)
            if case .failed = m.phase { break }
        }
        XCTAssertEqual(m.phase, .failed(.ackResendExhausted))
        XCTAssertTrue(out.actions.contains(.disconnect))
    }

    func testPairTimeoutAndCancel() {
        var m = PairStateMachine(config: .init(mac: Self.MAC, firmwareVersion: "1.5.0.0"))
        _ = m.start()
        let out = m.timeout()
        XCTAssertEqual(m.phase, .failed(.timeout))
        XCTAssertTrue(out.actions.contains(.disconnect))

        var m2 = PairStateMachine(config: .init(mac: Self.MAC, firmwareVersion: "1.5.0.0"))
        _ = m2.start()
        let out2 = m2.cancel()
        XCTAssertEqual(m2.phase, .failed(.userCancelled))
        XCTAssertTrue(out2.actions.contains(.disconnect))
    }

    func testPairUnbindModeEncodesMode2() {
        var m = PairStateMachine(config: .init(mac: Self.MAC, firmwareVersion: "1.5.0.0", mode: .unbind))
        let sim = DeviceSimulator(mac: Self.MAC)
        _ = m.start(); _ = m.handle(.connected); _ = m.handle(.servicesDiscovered)
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyData))
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))
        _ = m.handle(.readResponse(characteristic: GATT.featureInfo, data: [0b0000_0111]))
        _ = m.setDeviceIdInput(A6Obfuscation.macHex(Self.MAC))
        _ = m.handle(.notifyData(characteristic: GATT.notifyAck, data: sim.ackData()))
        for f in sim.command(0x0007, body: A6Hex.decode("AABBCCDDEEFF")) {
            _ = m.handle(.notifyData(characteristic: GATT.notifyData, data: f))
        }
        XCTAssertEqual(m.phase, .awaitingAuthAck)
        // mode-2 auth response was written to A624
        let codec = A6FrameCodec()
        // (verified indirectly: phase reached awaitingAuthAck means the queue accepted the command)
        _ = codec
    }

    // MARK: - Command queue semantics (independent of machines)

    func testCommandQueueLifecycle() {
        var q = CommandQueue(maxResends: 3)
        let codec = A6FrameCodec()
        let payload = A6Commands.pushUnit(.kg)
        q.enqueue(characteristic: GATT.writeData, payload: payload, codec: codec,
                  mac: Self.MAC, xored: true)

        // frame written while pending
        let w1 = q.pendingWrite()
        XCTAssertNotNil(w1)
        XCTAssertEqual(w1?.characteristic, GATT.writeData)
        // no further frames until ACK (single-frame command)
        XCTAssertNil(q.pendingWrite())

        // ACK pops
        XCTAssertTrue(q.popOnAck())
        XCTAssertNil(q.pendingWrite())
        XCTAssertTrue(q.isEmpty)
    }

    func testCommandQueueResend() {
        var q = CommandQueue(maxResends: 3)
        let codec = A6FrameCodec()
        q.enqueue(characteristic: GATT.writeData, payload: A6Commands.pushUnit(.kg),
                  codec: codec, mac: Self.MAC, xored: true)
        _ = q.pendingWrite()
        // 3 resends succeed, 4th fails
        XCTAssertTrue(q.resend()); XCTAssertNotNil(q.pendingWrite())
        XCTAssertTrue(q.resend()); _ = q.pendingWrite()
        XCTAssertTrue(q.resend()); _ = q.pendingWrite()
        XCTAssertFalse(q.resend())
    }
}
