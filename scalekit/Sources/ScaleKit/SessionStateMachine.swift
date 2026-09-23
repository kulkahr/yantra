import Foundation

/// Measurement-session state machine — port of `FatScaleWorker`:
/// connect → notify → login(0x0007→0x0008 mode 0) → init(0x0009→0x000A)
/// → config pushes (0x1002/0x1001/0x1004)
/// → live stream (0x00E9 / real-time) → final record (0x4802) →
/// history drain (0x4802 × remainCount) → finish.
public struct SessionStateMachine {

    public enum Phase: Equatable {
        case idle
        case connecting
        case discovering
        case enablingNotify
        case awaitingLogin           // bound device: waiting for the scale's 0x0007 login challenge
        case awaitingInit            // waiting for device 0x0009
        case pushingConfig
        case live                    // armed; live frames may arrive
        case draining                // remainCount > 0
        case disconnecting
        case done
        case failed(A6SessionError)
    }

    public enum A6SessionError: Error, Equatable {
        case ackResendExhausted
        case protocolError(String)
        case userCancelled
    }

    public struct Config {
        public var mac: String
        public var firmwareVersion: String
        public var deviceId: String                 // bound record deviceId (12 hex)
        public var slot: Int = 1
        public var unit: UnitType = .kg
        public var profile: UserProfile?
        public var utcProvider: () -> UInt32
        public var timeZoneHex: () -> UInt8
        public var dateProvider: () -> (Int, Int, Int, Int, Int, Int)
        public var maxResends: Int = 3

        public init(mac: String, firmwareVersion: String, deviceId: String,
                    slot: Int = 1, unit: UnitType = .kg, profile: UserProfile? = nil,
                    utcProvider: @escaping () -> UInt32,
                    timeZoneHex: @escaping () -> UInt8,
                    dateProvider: @escaping () -> (Int, Int, Int, Int, Int, Int),
                    maxResends: Int = 3) {
            self.mac = mac
            self.firmwareVersion = firmwareVersion
            self.deviceId = deviceId
            self.slot = slot
            self.unit = unit
            self.profile = profile
            self.utcProvider = utcProvider
            self.timeZoneHex = timeZoneHex
            self.dateProvider = dateProvider
            self.maxResends = maxResends
        }
    }

    /// User profile mirroring the fields of `0x1001 pushUserInfo`.
    public struct UserProfile: Equatable {
        public var sexMale: Bool
        public var age: Int
        public var heightMeters: Double
        public var athlete: Bool
        public var activityLevel: Int
        public var weightKg: Double?        // nil → 0xFFFF (unset)

        public init(sexMale: Bool, age: Int, heightMeters: Double,
                    athlete: Bool = false, activityLevel: Int = 0, weightKg: Double? = nil) {
            self.sexMale = sexMale
            self.age = age
            self.heightMeters = heightMeters
            self.athlete = athlete
            self.activityLevel = activityLevel
            self.weightKg = weightKg
        }
    }

    // MARK: Outputs

    public struct Output {
        public var actions: [LinkAction] = []
        /// Parsed measurements produced by this event, in arrival order.
        public var measurements: [A6WeightRecord] = []
        /// Live stream samples (raw frames on the real-time path).
        public var liveSamples: [[UInt8]] = []
        public var drainFinished = false
    }

    // MARK: State

    public private(set) var phase: Phase = .idle
    public private(set) var config: Config
    public private(set) var queue: CommandQueue
    private var assembler: A6FrameCodec.PacketAssembler
    private let codec = A6FrameCodec()
    private var xored: Bool { FirmwareCompat.usesXor(config.firmwareVersion) }

    public private(set) var lastRecord: A6WeightRecord?
    public private(set) var verificationCode: String?
    public private(set) var remainingOnScale: Int = 0

    public init(config: Config) {
        self.config = config
        self.queue = CommandQueue(maxResends: config.maxResends)
        self.assembler = A6FrameCodec.PacketAssembler(mac: config.mac, xored: FirmwareCompat.usesXor(config.firmwareVersion))
    }

    // MARK: Lifecycle

    public mutating func start() -> Output {
        phase = .connecting
        return Output(actions: [.connect(macOrIdentifier: config.mac)])
    }

    public mutating func cancel() -> Output {
        phase = .failed(.userCancelled)
        return Output(actions: [.disconnect])
    }

    // MARK: Link events

    public mutating func handle(_ event: LinkEvent) -> Output {
        switch event {
        case .connected:
            guard phase == .connecting else { return Output() }
            phase = .discovering
            return Output(actions: [.discoverServices])

        case .servicesDiscovered:
            guard phase == .discovering else { return Output() }
            phase = .enablingNotify
            return Output(actions: [.enableNotify(characteristic: GATT.notifyData),
                                    .enableNotify(characteristic: GATT.notifyAck)])

        case .notifyEnabled(let c):
            guard phase == .enablingNotify, c == GATT.notifyAck else { return Output() }
            phase = .awaitingLogin
            return Output()   // device will send 0x0007 (login challenge), then 0x0009

        case .notifyData(let characteristic, let data):
            guard characteristic == GATT.notifyData || characteristic == GATT.notifyAck else { return Output() }
            return handleNotify(characteristic: characteristic, data: data)

        case .disconnected:
            if phase == .disconnecting {
                phase = .done
            } else if phase != .done && !isTerminal {
                phase = .failed(.protocolError("unexpected disconnect"))
            }
            return Output()

        case .commandTimedOut:
            if queue.resend() {
                return drainQueue()
            }
            phase = .failed(.ackResendExhausted)
            return Output(actions: [.disconnect])

        default:
            return Output()
        }
    }

    /// Explicit "start measurement" (0x4801 on). Optional — the scale also
    /// begins streaming on its own when a user steps on.
    public mutating func startMeasurement() -> Output {
        guard phase == .live else { return Output() }
        let payload = A6Commands.measureSetting(slot: config.slot, on: true)
        queue.enqueue(characteristic: GATT.writeData, payload: payload, codec: codec,
                      mac: config.mac, xored: xored)
        return drainQueue()
    }

    public mutating func stopMeasurement() -> Output {
        guard phase == .live else { return Output() }
        let payload = A6Commands.measureSetting(slot: config.slot, on: false)
        queue.enqueue(characteristic: GATT.writeData, payload: payload, codec: codec,
                      mac: config.mac, xored: xored)
        return drainQueue()
    }

    /// Host decides to clear scale memory after a successful drain (SRD-004 FR-4).
    public mutating func clearScaleMemory() -> Output {
        guard phase == .done || phase == .live else { return Output() }
        let payload = A6Commands.clearData(slot: config.slot, utc: config.utcProvider())
        queue.enqueue(characteristic: GATT.writeData, payload: payload, codec: codec,
                      mac: config.mac, xored: xored)
        return drainQueue()
    }

    // MARK: Internals

    private var isTerminal: Bool {
        switch phase {
        case .done, .failed: return true
        default: return false
        }
    }

    private mutating func handleNotify(characteristic: UUID, data: [UInt8]) -> Output {
        guard let frame = codec.decodeFrame(data, mac: config.mac, xored: xored) else { return Output() }

        if frame.count == 0 {
            let status = AckStatus(Int(frame.payload.first ?? 0))
            switch status {
            case .ok:
                _ = queue.popOnAck()
                // Decompiled parity: after each ACK the next queued command is
                // written immediately (`commandCacheQueue.poll(); handleDataPackage(peek())`),
                // and an emptied config flush completes the setup workflow.
                var out = Output()
                if queue.isEmpty && phase == .pushingConfig {
                    phase = .live               // WAITING_TO_RECEIVE_DATA equivalent
                }
                out.actions += drainQueue().actions
                return out
            case .fail:
                if queue.resend() { return drainQueue() }
                phase = .failed(.ackResendExhausted)
                return Output(actions: [.disconnect])
            case .unknown:
                return Output()
            }
        }

        guard let result = assembler.ingest(frame) else { return Output() }
        switch result {
        case .failure:
            return Output(actions: [.write(characteristic: GATT.writeAck,
                                           data: A6Commands.ack(ok: false, mac: config.mac, xored: xored))])
        case .success(let payload):
            var out = Output()
            out.actions.append(.write(characteristic: GATT.writeAck,
                                      data: A6Commands.ack(ok: true, mac: config.mac, xored: xored)))
            guard payload.count >= 2 else { return out }
            let cmd = UInt16(payload[0]) << 8 | UInt16(payload[1])

            switch cmd {
            case A6Command.receiverAuth.rawValue:
                // Decompiled FatScaleWorker case 4/5: on the scale's login challenge,
                // data-ACK + 0x0008 auth response with mode 0 (login, not bind/unbind).
                guard payload.count >= 8 else { return out }
                let code = A6Hex.encode(Array(payload[2..<8]))
                verificationCode = code
                let auth = A6Commands.authResponse(success: true,
                                                   verificationCodeHex6: code, mode: 0)
                queue.enqueue(characteristic: GATT.writeData, payload: auth, codec: codec,
                              mac: config.mac, xored: xored)
                phase = .awaitingInit
                out.actions += drainQueue().actions

            case A6Command.receiverInit.rawValue:
                // Hardware-verified: 0x0009 flags 0x18 → UTC + timezone only.
                let initResp = A6Commands.responseInit(utc: config.utcProvider(),
                                                      timeZoneHex: config.timeZoneHex())
                queue.enqueue(characteristic: GATT.writeData, payload: initResp, codec: codec,
                              mac: config.mac, xored: xored)
                // Config pushes right after (hardware parity: user-info + unit,
                // optionally clear-data/HR-switch — no time push).
                enqueueConfigPushes()
                phase = .pushingConfig
                out.actions += drainQueue().actions

            case A6Command.pushUserInfo.rawValue,
                 A6Command.pushTime.rawValue,
                 A6Command.pushUnit.rawValue,
                 A6Command.pushTarget.rawValue,
                 A6Command.pushClearData.rawValue,
                 A6Command.pushFormula.rawValue,
                 A6Command.pushHeartRateSwitch.rawValue,
                 A6Command.responseInit.rawValue,
                 A6Command.measureSetting.rawValue,
                 A6Command.receiveUserInfo.rawValue,
                 A6Command.receiveTarget.rawValue,
                 A6Command.receiveUnit.rawValue,
                 A6Command.settingCallback.rawValue:
                // echoes/callbacks — no state change
                break

            case A6Command.newMeasureData.rawValue:
                out.liveSamples.append(payload)

            case A6Command.weightData.rawValue:
                if let record = A6WeightRecordParser.parse(payload) {
                    // remainCount > 0 ⇒ stored-memory drain (weighed offline,
                    // possibly by someone else); a live weigh-in reports 0 —
                    // hosts use this for attribution (issue #9).
                    var rec = record
                    rec.fromMemoryDrain = record.remainCount > 0
                    out.measurements.append(rec)
                    lastRecord = rec
                    remainingOnScale = record.remainCount
                    if record.remainCount > 0 {
                        phase = .draining
                    } else if phase == .draining {
                        phase = .live
                        out.drainFinished = true
                    } else if phase == .pushingConfig || phase == .awaitingInit {
                        phase = .live
                    }
                }

            default:
                break
            }
            out.actions += drainQueue().actions
            return out
        }
    }

    private mutating func enqueueConfigPushes() {
        // Hardware-verified set (official app HCI capture, 2026-09-21):
        // user-info → unit → HR-switch. No time push (0x000A already set UTC/tz),
        // no clear-data push (clearing scale memory is a separate user action).
        // The scale confirms each with a 0x1000 setting callback.
        if let p = config.profile {
            queue.enqueue(characteristic: GATT.writeData,
                          payload: A6Commands.pushUserInfo(slot: config.slot,
                                                           sexMale: p.sexMale,
                                                           age: p.age,
                                                           heightMeters: p.heightMeters,
                                                           athlete: p.athlete,
                                                           activityLevel: p.activityLevel,
                                                           weightKg: p.weightKg),
                          codec: codec, mac: config.mac, xored: xored)
        }
        queue.enqueue(characteristic: GATT.writeData,
                      payload: A6Commands.pushUnit(config.unit),
                      codec: codec, mac: config.mac, xored: xored)
        queue.enqueue(characteristic: GATT.writeData,
                      payload: A6Commands.pushHeartRateSwitch(on: true),
                      codec: codec, mac: config.mac, xored: xored)
    }

    private mutating func drainQueue() -> Output {
        var actions: [LinkAction] = []
        while let w = queue.pendingWrite() {
            actions.append(.write(characteristic: w.characteristic, data: w.frame))
        }
        return Output(actions: actions)
    }

    /// Disconnect politely after drain/live work is finished.
    public mutating func finish() -> Output {
        phase = .disconnecting
        return Output(actions: [.disconnect])
    }
}
