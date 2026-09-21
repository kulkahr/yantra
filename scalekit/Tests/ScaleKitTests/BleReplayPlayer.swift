import Foundation
@testable import ScaleKit

/// Replays *recorded* device→app notify sequences (JSON captures, see
/// `analysis/captures/README.md`) against the ScaleKit state machines.
///
/// Unlike `DeviceSimulator` — which generates traffic from our own protocol
/// understanding — this player feeds captures verbatim, so a wrong wire
/// assumption surfaces as a test failure instead of silently passing.
struct BleReplayPlayer {

    struct Capture {
        struct Meta {
            var kind: Kind
            enum Kind: String { case pair, session }
        }
        var meta: Meta
        /// Raw notify bytes per event, in arrival order.
        var events: [(characteristic: UUID, data: [UInt8])]
    }

    enum ReplayError: Error, Equatable {
        case malformedCapture(String)
    }

    // MARK: - Loading

    static func load(data: Data) throws -> Capture {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = obj["meta"] as? [String: Any],
              let kindRaw = meta["kind"] as? String,
              let kind = Capture.Meta.Kind(rawValue: kindRaw),
              let events = obj["events"] as? [[String: Any]] else {
            throw ReplayError.malformedCapture("missing meta/events fields")
        }

        var parsed: [(UUID, [UInt8])] = []
        for (i, e) in events.enumerated() {
            guard let charRaw = e["char"] as? String,
                  let hex = e["hex"] as? String else {
                throw ReplayError.malformedCapture("event \(i): missing char/hex")
            }
            let uuid: UUID
            if charRaw.count == 4, charRaw.allSatisfy({ $0.isHexDigit }) {
                uuid = UUID(uuidString: "0000\(charRaw.uppercased())-0000-1000-8000-00805F9B34FB")!
            } else if let u = UUID(uuidString: charRaw) {
                uuid = u
            } else {
                throw ReplayError.malformedCapture("event \(i): bad characteristic '\(charRaw)'")
            }
            guard hex.count % 2 == 0 else {
                throw ReplayError.malformedCapture("event \(i): odd hex length")
            }
            parsed.append((uuid, A6Hex.decode(hex)))
        }
        return Capture(meta: .init(kind: kind), events: parsed)
    }

    static func load(resource name: String, bundle: Bundle = Bundle.module) throws -> Capture {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw ReplayError.malformedCapture("resource not found: \(name).json")
        }
        return try load(data: try Data(contentsOf: url))
    }

    // MARK: - Replaying

    /// Everything the machine emitted while the capture was pumped through it.
    struct Transcript {
        /// Writes the host would have issued, in order (to A624 commands / A622 ACKs).
        var writes: [LinkAction] = []
        var disconnectRequested = false
    }

    /// Drives the session machine through a capture.
    ///
    /// The harness behaves like the real host: machine outputs that request link
    /// lifecycle work (connect/discover/enable-notify) are the canned events the
    /// host answers with; every `write` is recorded verbatim into the transcript
    /// (the device's ACKs are already part of the recording, so nothing is
    /// synthesized here).
    static func replaySession(_ capture: Capture, config: SessionStateMachine.Config) throws
        -> (machine: SessionStateMachine, transcript: Transcript) {
        guard capture.meta.kind == .session else {
            throw ReplayError.malformedCapture("capture kind is not session")
        }
        var m = SessionStateMachine(config: config)
        var t = Transcript()

        func service(_ out: SessionStateMachine.Output) {
            for action in out.actions {
                switch action {
                case .write(let c, let d): t.writes.append(.write(characteristic: c, data: d))
                case .disconnect: t.disconnectRequested = true
                case .connect, .discoverServices, .enableNotify, .read:
                    break // host lifecycle — covered by the canned sequence below
                }
            }
        }

        service(m.start())
        service(m.handle(.connected))
        service(m.handle(.servicesDiscovered))
        service(m.handle(.notifyEnabled(characteristic: GATT.notifyData)))
        service(m.handle(.notifyEnabled(characteristic: GATT.notifyAck)))

        for (char, data) in capture.events {
            service(m.handle(.notifyData(characteristic: char, data: data)))
        }
        return (m, t)
    }

    /// Drives the pair machine through a capture.
    ///
    /// `deviceIdInput` / `bindConfirm` are host decisions (from E1); they are
    /// applied the moment the machine reaches its corresponding gate phase.
    /// `featureBitmap` is injected for the A641 read response — a real capture
    /// will include it once E1 records read responses too (open item).
    static func replayPair(_ capture: Capture, config: PairStateMachine.Config,
                           deviceIdInput: String, bindConfirm: Bool,
                           featureBitmap: [UInt8] = []) throws
        -> (machine: PairStateMachine, transcript: Transcript) {
        guard capture.meta.kind == .pair else {
            throw ReplayError.malformedCapture("capture kind is not pair")
        }
        var m = PairStateMachine(config: config)
        var t = Transcript()

        func service(_ out: PairStateMachine.Output) {
            for action in out.actions {
                switch action {
                case .write(let c, let d): t.writes.append(.write(characteristic: c, data: d))
                case .disconnect: t.disconnectRequested = true
                case .connect, .discoverServices, .enableNotify, .read:
                    break
                }
            }
        }

        service(m.start())
        service(m.handle(.connected))
        service(m.handle(.servicesDiscovered))
        service(m.handle(.notifyEnabled(characteristic: GATT.notifyData)))
        service(m.handle(.notifyEnabled(characteristic: GATT.notifyAck)))
        service(m.handle(.readResponse(characteristic: GATT.featureInfo, data: featureBitmap)))

        var didInput = false
        var didConfirm = false
        for (char, data) in capture.events {
            for action in m.handle(.notifyData(characteristic: char, data: data)).actions {
                // A real host services disconnect requests immediately (polite
                // GATT close); the machine then completes its `.done` transition.
                if action == .disconnect {
                    t.disconnectRequested = true
                    _ = m.handle(.disconnected)
                } else {
                    t.writes.append(action)
                }
            }
            if case .awaitingDeviceIdInput = m.phase, !didInput {
                didInput = true
                service(m.setDeviceIdInput(deviceIdInput))
            }
            if case .awaitingBindConfirm = m.phase, !didConfirm {
                didConfirm = true
                let state: PairedConfirmState = bindConfirm ? .pairingSuccess : .pairingFail
                service(m.setBindConfirm(state, slot: config.userSlot))
            }
        }
        return (m, t)
    }
}
