import Foundation
import ScaleKit

// MARK: - Shared plumbing

/// Watchdog bookkeeping shared by both drivers: the 3 s resend timer is armed
/// exactly while a command is in flight (queue non-empty or frames pending),
/// matching the decompiled 3 s resend semantics.
enum Watchdog {
    static func sync(_ queue: CommandQueue, host: BleHost?) {
        if queue.isWritePending || !queue.isEmpty {
            host?.armWatchdog()
        } else {
            host?.disarmWatchdog()
        }
    }
}

/// Console output sink.
final class Console: DriverOutput {
    func printLine(_ s: String) { print(s); fflush(stdout) }
}

// MARK: - E1: pair driver

/// Drives `PairStateMachine` against the physical scale (experiment E1) and
/// records the whole flow as a `pair` capture for the replay harness.
final class PairDriver: ScaleDriver {
    let recorder: CaptureRecorder
    weak var host: BleHost?

    private var machine: PairStateMachine?
    private let slot: Int
    private let mode: PairStateMachine.Mode
    private let skipRegister: Bool
    /// Override for the register command's deviceId (e.g. presenting an identity
    /// the scale may already know — the challenge is only sent to known deviceIds).
    private let deviceIdOverride: String?
    /// Skip the 180a/A641/A640 reads entirely (they stall on this firmware and
    /// burn the active window; the protocol does not require them).
    private let fast: Bool
    private(set) var bindRecord: PairStateMachine.BindRecord?

    init(host: BleHost, slot: Int, mode: PairStateMachine.Mode, skipRegister: Bool,
         notes: String, deviceIdOverride: String? = nil, fast: Bool = false) {
        self.host = host
        self.slot = slot
        self.mode = mode
        self.skipRegister = skipRegister
        self.deviceIdOverride = deviceIdOverride
        self.fast = fast
        self.recorder = CaptureRecorder(mac: host.mac, firmwareVersion: "unknown",
                                        kind: "pair", notes: notes)
    }

    func readsAfterDiscovery() -> [UUID] {
        fast ? [] : [GATTPlus.firmwareRevision, GATTPlus.modelNumber, GATTPlus.manufacturerName,
                     GATT.featureInfo, GATT.voltage]
    }

    /// Machine construction happens after link setup + reads, so the connect/
    /// discover/notify/read lifecycle is replayed as the canned event sequence
    /// (identical to the unit tests), then the host decisions are applied.
    func startMachine(fw: String, reads: [UUID: Data]) {
        recorder.firmwareVersion = fw.isEmpty ? "unknown" : fw
        let config = PairStateMachine.Config(
            mac: host?.mac ?? recorder.mac,
            firmwareVersion: fw,
            mode: mode,
            userSlot: slot,
            registerState: deviceIdOverride != nil ? .registered : .normalUnregister,
            skipsRegister: skipRegister)
        var m = PairStateMachine(config: config)
        host?.out.printLine("pair machine started (fw \(fw.isEmpty ? "?" : fw), xored=\(FirmwareCompat.usesXor(fw.isEmpty ? "0" : fw)))")

        // Canned link lifecycle (host already performed the real work). The
        // machine starts in .idle — .connected is only accepted from .connecting,
        // so start() must run first; its connect action is consumed by the host.
        _ = m.start()
        _ = m.handle(.connected)
        _ = m.handle(.servicesDiscovered)
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyData))
        var out = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))

        // Machine gates on host inputs after the read phase; the protocol itself
        // does not require the A641 value to proceed, so feed the canned
        // read-response event even if the read stalled (E1 verifies the rest).
        if m.phase == .readingDeviceInfo {
            let feat = reads[GATT.featureInfo].map { [UInt8]($0) } ?? []
            out.actions += m.handle(.readResponse(characteristic: GATT.featureInfo,
                                                  data: feat)).actions
        }
        if case .awaitingDeviceIdInput = m.phase {
            let devId = deviceIdOverride ?? A6Obfuscation.macHex(config.mac)
            out.actions += m.setDeviceIdInput(devId).actions
        }
        if case .awaitingChallenge = m.phase {
            host?.out.printLine("⏳ waiting for the scale's auth challenge (0x0007) — STEP ON THE SCALE now")
        }

        machine = m
        host?.performAll(out.actions)
        Watchdog.sync(m.queue, host: host)
    }

    func dispatch(_ event: LinkEvent) -> [LinkAction] {
        guard var m = machine else { return [] }
        var out = m.handle(event)

        // Host decision gate: confirm the bind as soon as the machine asks.
        if case .awaitingBindConfirm = m.phase {
            out.actions += m.setBindConfirm(.pairingSuccess, slot: slot).actions
        }

        machine = m
        Watchdog.sync(m.queue, host: host)
        if let rec = out.bindRecord { bindRecord = rec }
        return out.actions
    }

    var statusLine: String {
        guard let m = machine else { return "pair: (waiting for link setup)" }
        return "pair: \(m.phase)"
    }

    var isFinished: Bool {
        guard let m = machine else { return false }
        switch m.phase {
        case .done, .failed: return true
        default: return false
        }
    }

    var summary: String {
        guard let m = machine else { return "pair: never started" }
        if let rec = bindRecord {
            let feat = rec.featureBitmap.map { $0.map { String(format: "%02X", $0) }.joined() } ?? "-"
            return """
            E1 RESULT: BOUND ✓
              deviceId = \(rec.deviceId)
              mac      = \(rec.mac)
              slot     = \(rec.slot)
              firmware = \(rec.firmwareVersion)
              feature  = \(feat)
            U1 CLOSED: the scale accepted a bind from a third-party host — auth is
            device-local (verificationCode ⊕ MAC); no cloud, no secret involved.
            """
        }
        return "E1 RESULT: NOT BOUND — machine ended in \(m.phase)\n(see transcript; capture saved regardless for diffing)"
    }
}

// MARK: - E2: session driver

/// Drives `SessionStateMachine` against the physical scale (experiment E2) and
/// records the whole flow as a `session` capture — including the live-stream
/// frames that settle unknown U2.
final class SessionDriver: ScaleDriver {
    let recorder: CaptureRecorder
    weak var host: BleHost?

    private var machine: SessionStateMachine?
    private var measurements: [A6WeightRecord] = []
    private var liveSamples = 0
    private let slot: Int
    private let unit: UnitType
    private let armMeasurement: Bool
    private var didArm = false
    private var u2ClassCounts: [String: Int] = [:]

    init(host: BleHost, slot: Int, unit: UnitType, armMeasurement: Bool, notes: String) {
        self.host = host
        self.slot = slot
        self.unit = unit
        self.armMeasurement = armMeasurement
        self.recorder = CaptureRecorder(mac: host.mac, firmwareVersion: "unknown",
                                        kind: "session", notes: notes)
    }


    func readsAfterDiscovery() -> [UUID] {
        [GATTPlus.firmwareRevision, GATTPlus.modelNumber, GATTPlus.manufacturerName,
         GATT.featureInfo, GATT.voltage]
    }

    func startMachine(fw: String, reads: [UUID: Data]) {
        recorder.firmwareVersion = fw.isEmpty ? "unknown" : fw
        let mac = host?.mac ?? recorder.mac
        let profile = SessionStateMachine.UserProfile(
            sexMale: true, age: 33, heightMeters: 1.75)   // demo profile — keep consistent vs official app
        let config = SessionStateMachine.Config(
            mac: mac,
            firmwareVersion: fw,
            deviceId: SessionDriver.persistedDeviceId(for: mac),
            slot: slot,
            unit: unit,
            profile: profile,
            utcProvider: { UInt32(Date().timeIntervalSince1970) },
            timeZoneHex: {
                // Decompiled DateUtils.getTimezoneCode: code = (offsetMinutes/15)+48.
                // Hardware-verified: IST +5:30 → (330/15)+48 = 70 = 0x46.
                let minutes = TimeZone.current.secondsFromGMT() / 60
                return UInt8(truncatingIfNeeded: (minutes / 15) + 48)
            },
            dateProvider: {
                let c = Calendar(identifier: .gregorian).dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: Date())
                return (c.year ?? 2026, c.month ?? 1, c.day ?? 1,
                        c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
            })
        var m = SessionStateMachine(config: config)
        host?.out.printLine("session machine started (fw \(fw.isEmpty ? "?" : fw), xored=\(FirmwareCompat.usesXor(fw.isEmpty ? "0" : fw)), deviceId \(config.deviceId))")

        // Canned link lifecycle; the machine then waits for the scale's 0x0009.
        // start() first (same phase-guard reason as the pair machine).
        _ = m.start()
        _ = m.handle(.connected)
        _ = m.handle(.servicesDiscovered)
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyData))
        _ = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))

        machine = m
        Watchdog.sync(m.queue, host: host)
    }

    func dispatch(_ event: LinkEvent) -> [LinkAction] {
        guard var m = machine else { return [] }
        var out = m.handle(event)
        machine = m
        Watchdog.sync(m.queue, host: host)

        measurements.append(contentsOf: out.measurements)
        liveSamples += out.liveSamples.count

        // U2 instrumentation: classify every notify by its first two wire bytes
        // (pre-reassembly view) — the classification SRD-003 needs.
        if case .notifyData(_, let data) = event, data.count >= 2 {
            let cmd = String(format: "%04X", UInt16(data[0]) << 8 | UInt16(data[1]))
            u2ClassCounts[cmd, default: 0] += 1
        }

        // Optional: arm measurement (0x4801 on) the first time we go live.
        if armMeasurement, !didArm, m.phase == .live {
            didArm = true
            out.actions += m.startMeasurement().actions
            Watchdog.sync(m.queue, host: host)
        }

        for meas in out.measurements {
            host?.out.printLine("✔ record: \(meas.weightKg) kg (remain \(meas.remainCount), unit \(meas.unitRaw), impedance \(meas.impedanceOhm.map(String.init) ?? "-"))")
        }
        return out.actions
    }

    var statusLine: String {
        guard let m = machine else { return "session: (waiting for link setup)" }
        return "session: \(m.phase) · records \(measurements.count) · live \(liveSamples)"
    }

    var isFinished: Bool {
        guard let m = machine else { return false }
        switch m.phase {
        case .done, .failed: return true
        default: return false
        }
    }

    var summary: String {
        guard let m = machine else { return "session: never started" }
        var lines = ["E2 RESULT: \(m.phase)"]
        lines.append("  records: \(measurements.count) · live samples: \(liveSamples)")
        if let last = measurements.last {
            lines.append("  last: \(last.weightKg) kg · impedance \(last.impedanceOhm.map(String.init) ?? "-") Ω · remain \(last.remainCount)")
        }
        lines.append("  U2 notify classification (first two wire bytes per notify):")
        for (cmd, n) in u2ClassCounts.sorted(by: { $0.key < $1.key }) {
            lines.append("    \(cmd): ×\(n)")
        }
        lines.append("""
            U2 NOTE: 0x00E9-final-records vs raw short frames — if short unknown
            frames dominate during weigh-ins, the live path is NOT 0x00E9 on this
            firmware; feed the capture to BleReplayPlayer to reproduce exactly.
            """)
        return lines.joined(separator: "\n")
    }

    /// deviceId for sessions = the E1 bind's derived value (verificationCode ⊕ MAC)
    /// when available; otherwise the MAC itself (official default).
    static func persistedDeviceId(for mac: String) -> String {
        if let data = try? Data(contentsOf: BindStore.fileURL),
           let rec = try? JSONDecoder().decode(BindStore.Record.self, from: data),
           rec.mac == mac {
            return rec.deviceId
        }
        return A6Obfuscation.macHex(mac)
    }
}

/// Persists the E1 bind result so E2 can reuse the derived deviceId.
enum BindStore {
    struct Record: Codable {
        var deviceId: String
        var mac: String
        var slot: Int
        var firmwareVersion: String
        var boundAt: Date
    }

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("a6host", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bind.json")
    }

    static func save(_ rec: PairStateMachine.BindRecord) {
        let r = Record(deviceId: rec.deviceId, mac: rec.mac, slot: rec.slot,
                       firmwareVersion: rec.firmwareVersion, boundAt: rec.boundAt)
        if let d = try? JSONEncoder().encode(r) {
            try? d.write(to: fileURL, options: .atomic)
        }
    }
}
