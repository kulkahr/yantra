import Foundation

/// Pairing/binding state machine — port of `FatScalePairWorker`:
/// connect → notify → deviceInfo → feature → register(0x0001) →
/// challenge(0x0007) → authResponse(0x0008) → bindNotice(0x0003) →
/// bindResult(0x0004) → disconnect.
public struct PairStateMachine {

    public enum Phase: Equatable {
        case idle
        case connecting
        case discovering
        case enablingNotify
        case readingDeviceInfo
        case readingFeature
        case awaitingDeviceIdInput
        case registering          // WRITE_REGISTER
        case awaitingChallenge    // RECEIVE_AUTH
        case awaitingAuthAck      // auth response written, waiting device ACK
        case awaitingBindConfirm  // REQUEST_BIND_STATE — host/user decides
        case binding              // WRITE_BIND_NOTICE
        case disconnecting
        case done
        case failed(A6PairError)
    }

    public enum A6PairError: Error, Equatable {
        case registerRejected      // 0x0002 result = 2
        case bindRefused           // 0x0004 result = 2
        case timeout               // 180 s pair window elapsed
        case bluetoothClosed
        case userCancelled
        case featureNotBindable    // feature bitmap says not bindable/unbindable
        case ackResendExhausted
        case protocolError(String)
    }

    /// Purpose of this pairing session.
    public enum Mode { case bind, unbind }

    // MARK: Inputs (host-supplied context)

    public struct Config {
        public var mac: String
        public var firmwareVersion: String          // from 180a:2a26 (or empty if unreadable)
        public var mode: Mode = .bind
        public var userSlot: Int = 1                // USER1, per official DefaultPairCallback
        public var registerState: RegisterState = .normalUnregister
        public var maxResends: Int = 3
        /// E1 finding: the official pairing stack only runs REQUEST_DEVICE_ID →
        /// WRITE_REGISTER when the advertised register-status byte == 0
        /// (ProtocolType.getPairingProtocolStack). Retail units advertise 1 and
        /// skip straight to RECEIVE_AUTH — the challenge is device-initiated
        /// (step-on triggers it).
        public var skipsRegister: Bool = false

        public init(mac: String, firmwareVersion: String, mode: Mode = .bind,
                    userSlot: Int = 1, registerState: RegisterState = .normalUnregister,
                    maxResends: Int = 3, skipsRegister: Bool = false) {
            self.mac = mac
            self.firmwareVersion = firmwareVersion
            self.mode = mode
            self.userSlot = userSlot
            self.registerState = registerState
            self.maxResends = maxResends
            self.skipsRegister = skipsRegister
        }
    }

    // MARK: Outputs

    public struct Output {
        public var actions: [LinkAction] = []
        public var bindRecord: BindRecord?
    }

    /// Result of a completed pairing session (SRD-002 data model).
    public struct BindRecord: Equatable {
        public var deviceId: String        // 12 hex chars
        public var mac: String
        public var slot: Int
        public var firmwareVersion: String
        public var featureBitmap: [UInt8]?
        public var boundAt: Date
    }

    // MARK: State

    public private(set) var phase: Phase = .idle
    public private(set) var config: Config
    public private(set) var queue: CommandQueue
    public private(set) var featureBitmap: [UInt8]?
    public private(set) var verificationCode: String?
    /// Set when the machine is in `.awaitingDeviceIdInput` / `.awaitingBindConfirm`
    /// and the host must call `setDeviceIdInput` / `setBindConfirm` to continue.
    private var assembler: A6FrameCodec.PacketAssembler
    private let codec = A6FrameCodec()
    private var xored: Bool { FirmwareCompat.usesXor(config.firmwareVersion) }
    private var awaitingDeviceId = false
    private var awaitingConfirm = false
    private var pendingRegisterPayload: [UInt8]?

    public init(config: Config) {
        self.config = config
        self.queue = CommandQueue(maxResends: config.maxResends)
        self.assembler = A6FrameCodec.PacketAssembler(mac: config.mac, xored: FirmwareCompat.usesXor(config.firmwareVersion))
    }

    // MARK: Lifecycle

    public mutating func start() -> Output {
        transition(to: .connecting)
        return Output(actions: [.connect(macOrIdentifier: config.mac)])
    }

    public mutating func cancel() -> Output {
        transition(to: .failed(.userCancelled))
        return Output(actions: [.disconnect])
    }

    /// 180 s pair-window timer elapsed (host responsibility).
    public mutating func timeout() -> Output {
        transition(to: .failed(.timeout))
        return Output(actions: [.disconnect])
    }

    /// Bluetooth turned off mid-pair.
    public mutating func bluetoothClosed() -> Output {
        transition(to: .failed(.bluetoothClosed))
        return Output(actions: [.disconnect])
    }

    // MARK: Host inputs

    /// Host supplies the deviceId to register (official default: MAC without colons;
    /// alternative: challenge-derived `A6Commands.deviceId(...)`). Only consumed
    /// while the machine is waiting in `.awaitingDeviceIdInput`.
    public mutating func setDeviceIdInput(_ deviceIdHex12: String) -> Output {
        guard phase == .awaitingDeviceIdInput, awaitingDeviceId else { return Output() }
        awaitingDeviceId = false
        let payload = A6Commands.register(deviceIdHex12: deviceIdHex12,
                                          state: config.registerState,
                                          mac: config.mac)
        pendingRegisterPayload = payload
        queue.enqueue(characteristic: GATT.writeData, payload: payload, codec: codec,
                      mac: config.mac, xored: xored)
        transition(to: .registering)
        return drainQueue()
    }

    /// Host confirms/refuses the bind (official default: confirm, slot 1).
    public mutating func setBindConfirm(_ confirm: PairedConfirmState, slot: Int) -> Output {
        guard phase == .awaitingBindConfirm, awaitingConfirm else { return Output() }
        awaitingConfirm = false
        let payload = A6Commands.bindNotice(userNumber: slot, confirm: confirm)
        queue.enqueue(characteristic: GATT.writeData, payload: payload, codec: codec,
                      mac: config.mac, xored: xored)
        if confirm == .pairingSuccess {
            transition(to: .binding)
        } else {
            // refused → device replies bindResult; we treat as graceful stop
            transition(to: .binding)
        }
        return drainQueue()
    }

    // MARK: Link events

    public mutating func handle(_ event: LinkEvent) -> Output {
        switch event {
        case .connected:
            guard phase == .connecting else { return Output() }
            transition(to: .discovering)
            return Output(actions: [.discoverServices])

        case .servicesDiscovered:
            guard phase == .discovering else { return Output() }
            transition(to: .enablingNotify)
            return Output(actions: [
                .enableNotify(characteristic: GATT.notifyData),
                .enableNotify(characteristic: GATT.notifyAck),
            ])

        case .notifyEnabled(let c):
            guard phase == .enablingNotify else { return Output() }
            if c == GATT.notifyAck {
                transition(to: .readingDeviceInfo)
                return Output(actions: [.read(characteristic: GATT.voltage)])  // fw via 180a read below
            }
            return Output()

        case .readResponse(let characteristic, let data):
            guard phase == .readingDeviceInfo else { return Output() }
            // 180a reads and A640/A641 land here; A641 = feature bitmap
            if characteristic == GATT.featureInfo {
                featureBitmap = data
            }
            if config.skipsRegister {
                // Retail path (advertised register-status 1): no register command;
                // the scale sends 0x0007 spontaneously (typically on step-on).
                transition(to: .awaitingChallenge)
                return Output()
            }
            // Factory path (register-status 0): host supplies the deviceId.
            transition(to: .awaitingDeviceIdInput)
            awaitingDeviceId = true
            return Output()   // host must call setDeviceIdInput

        case .notifyData(let characteristic, let data):
            guard characteristic == GATT.notifyData || characteristic == GATT.notifyAck else { return Output() }
            return handleNotify(characteristic: characteristic, data: data)

        case .disconnected:
            switch phase {
            case .disconnecting:
                transition(to: .done)
                return Output()
            case .failed:
                return Output()   // already terminal
            default:
                transition(to: .failed(.protocolError("unexpected disconnect")))
                return Output()
            }

        case .commandTimedOut:
            return handleResendTick()
        }
    }

    // MARK: Internals

    private mutating func handleNotify(characteristic: UUID, data: [UInt8]) -> Output {
        guard let frame = codec.decodeFrame(data, mac: config.mac, xored: xored) else {
            return Output()
        }

        // ACK packets (count == 0): pop head command or fail
        if frame.count == 0 {
            let status = AckStatus(Int(frame.payload.first ?? 0))
            switch status {
            case .ok:
                guard queue.popOnAck() else {
                    return Output()
                }
                return advanceAfterAck()
            case .fail:
                return Output(actions: drainResend())
            case .unknown:
                return Output()
            }
        }

        // Data packets: reassemble (multi-frame capable)
        guard let result = assembler.ingest(frame) else { return Output() }
        switch result {
        case .failure:
            // CRC bad → ACK fail, device resends
            return Output(actions: [.write(characteristic: GATT.writeAck,
                                           data: A6Commands.ack(ok: false, mac: config.mac, xored: xored))])
        case .success(let payload):
            var actions: [LinkAction] = [.write(characteristic: GATT.writeAck,
                                                data: A6Commands.ack(ok: true, mac: config.mac, xored: xored))]
            guard payload.count >= 2 else { return Output(actions: actions) }
            let cmd = UInt16(payload[0]) << 8 | UInt16(payload[1])
            switch cmd {
            case A6Command.deviceRegisterResult.rawValue:
                let (value, _) = ResultValue.parse(payload)
                if value == ResultValue.success {
                    // keep draining queue (auth response may be queued next); wait for challenge
                    return Output(actions: actions)
                } else {
                    transition(to: .failed(.registerRejected))
                    return Output(actions: actions + [.disconnect])
                }
            case A6Command.receiverAuth.rawValue:
                // payload = [cmd(2B)][code(6B)] → verificationCode = payload[2..<8]... 
                // decompiled: data.substring(4, 16) on the HEX STRING = bytes 2..8 of the packet data
                // (packet data includes the 2-byte command header → bytes 2..<8 of full payload = code)
                let codeBytes = Array(payload[2..<8])
                verificationCode = A6Hex.encode(codeBytes)
                // enqueue auth response immediately (machine drives it, not the host)
                guard let vc = verificationCode else { return Output(actions: actions) }
                let auth = A6Commands.authResponse(success: true,
                                                   verificationCodeHex6: vc,
                                                   mode: config.mode == .bind ? 1 : 2)
                queue.enqueue(characteristic: GATT.writeData, payload: auth, codec: codec,
                              mac: config.mac, xored: xored)
                transition(to: .awaitingAuthAck)
                return Output(actions: actions + drainQueue().actions)
            case A6Command.bindResult.rawValue:
                let (value, _) = ResultValue.parse(payload)
                if value == ResultValue.success {
                    transition(to: .disconnecting)
                    let record = BindRecord(deviceId: pendingDeviceId ?? A6Obfuscation.macHex(config.mac),
                                            mac: config.mac,
                                            slot: config.userSlot,
                                            firmwareVersion: config.firmwareVersion,
                                            featureBitmap: featureBitmap,
                                            boundAt: Date())
                    actions.append(.disconnect)
                    phase = .disconnecting
                    return Output(actions: actions, bindRecord: record)
                } else {
                    transition(to: .failed(.bindRefused))
                    actions.append(.disconnect)
                    return Output(actions: actions)
                }
            default:
                return Output(actions: actions)
            }
        }
    }

    private var pendingDeviceId: String?

    private mutating func advanceAfterAck() -> Output {
        var out = Output()
        switch phase {
        case .awaitingAuthAck:
            // auth response ACKed → ask host/user for bind confirmation
            transition(to: .awaitingBindConfirm)
            awaitingConfirm = true
        case .registering:
            // register ACKed → wait for 0x0002 result packet (device-initiated)
            break
        case .binding:
            // bindNotice ACKed → wait for 0x0004 bindResult packet
            break
        default:
            break
        }
        // Decompiled parity: write the next queued command right away, if any.
        out.actions += drainQueue().actions
        return out
    }

    private mutating func drainQueue() -> Output {
        var actions: [LinkAction] = []
        while let w = queue.pendingWrite() {
            actions.append(.write(characteristic: w.characteristic, data: w.frame))
        }
        return Output(actions: actions)
    }

    private func drainResend() -> [LinkAction] {
        // On ACK-fail the official code re-sends the head command immediately.
        // Mutating method required; handled in handleResendTick path.
        []
    }

    private mutating func handleResendTick() -> Output {
        if queue.resend() {
            return drainQueue()
        }
        transition(to: .failed(.ackResendExhausted))
        return Output(actions: [.disconnect])
    }

    private mutating func transition(to p: Phase) {
        phase = p
    }
}
