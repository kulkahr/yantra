import Foundation
import ScaleKit

/// `a6host replay <capture.json>` — feeds a recorded capture (schema v1,
/// `analysis/captures/README.md`) through the appropriate state machine and
/// prints the machine transcript: writes it would issue, final phase.
/// Mirrors `BleReplayPlayer` in the test target (same loading rules).
enum ReplayCommand {

    static func run(path: String, slot: Int, macOverride: String?) -> Int32 {
        let url = URL(fileURLWithPath: path)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            print("cannot read \(url.path)")
            return 2
        }

        // Parse the capture with the same rules as BleReplayPlayer.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = obj["meta"] as? [String: Any],
              let kindRaw = meta["kind"] as? String,
              let events = obj["events"] as? [[String: Any]] else {
            print("malformed capture (missing meta/events)")
            return 2
        }
        let mac = (macOverride ?? (meta["mac"] as? String)) ?? ""
        let fw = (meta["firmwareVersion"] as? String) ?? "1.5.0.0"

        func uuid(_ short: String) -> UUID {
            UUID(uuidString: "0000\(short.uppercased())-0000-1000-8000-00805F9B34FB")!
        }

        var readEvents: [(UUID, [UInt8])] = []
        var notifyEvents: [(UUID, [UInt8])] = []
        for e in events {
            guard let charRaw = e["char"] as? String,
                  let hex = e["hex"] as? String else { continue }
            let u = charRaw.count == 4 ? uuid(charRaw)
                : (UUID(uuidString: charRaw) ?? uuid("A621"))
            let bytes = A6Hex.decode(hex)
            if (e["read"] as? Bool) == true {
                readEvents.append((u, bytes))
            } else {
                notifyEvents.append((u, bytes))
            }
        }

        print("replaying \(url.lastPathComponent): mac \(mac), fw \(fw), kind \(kindRaw), "
            + "\(notifyEvents.count) notify + \(readEvents.count) read events")

        switch kindRaw {
        case "pair":
            var m = PairStateMachine(config: .init(mac: mac, firmwareVersion: fw,
                                                   userSlot: slot, skipsRegister: true))
            var writes: [String] = []
            func pump(_ out: PairStateMachine.Output) {
                for a in out.actions {
                    switch a {
                    case .write(_, let d):
                        writes.append("write " + A6Hex.encode(d))
                    case .disconnect:
                        writes.append("disconnect")
                    default: break
                    }
                }
            }
            _ = m.start()
            _ = m.handle(.connected)
            _ = m.handle(.servicesDiscovered)
            _ = m.handle(.notifyEnabled(characteristic: GATT.notifyData))
            _ = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))
            pump(m.handle(.readResponse(characteristic: GATT.featureInfo, data: [])))
            if case .awaitingDeviceIdInput = m.phase {
                pump(m.setDeviceIdInput(A6Obfuscation.macHex(mac)))
            }
            for (u, bytes) in readEvents + notifyEvents {
                pump(m.handle(.notifyData(characteristic: u, data: bytes)))
                if case .awaitingBindConfirm = m.phase {
                    pump(m.setBindConfirm(.pairingSuccess, slot: slot))
                }
            }
            print("final phase: \(m.phase)")
            print("verificationCode: \(m.verificationCode ?? "-")")
            if let vc = m.verificationCode {
                print("derived deviceId: \(A6Commands.deviceId(verificationCodeHex6: vc, mac: mac))")
            }
            print("transcript (\(writes.count) actions):")
            for w in writes { print("  " + w) }
            return 0

        case "session":
            var m = SessionStateMachine(config: .init(
                mac: mac, firmwareVersion: fw, deviceId: A6Obfuscation.macHex(mac),
                slot: slot, unit: .kg,
                profile: .init(sexMale: true, age: 33, heightMeters: 1.75),
                utcProvider: { UInt32(Date().timeIntervalSince1970) },
                timeZoneHex: { 0x2A },
                dateProvider: { (2026, 9, 21, 12, 0, 0) }))
            var records: [A6WeightRecord] = []
            var live = 0
            func pump(_ out: SessionStateMachine.Output) {
                records += out.measurements
                live += out.liveSamples.count
            }
            _ = m.start()
            _ = m.handle(.connected)
            _ = m.handle(.servicesDiscovered)
            _ = m.handle(.notifyEnabled(characteristic: GATT.notifyData))
            _ = m.handle(.notifyEnabled(characteristic: GATT.notifyAck))
            for (u, bytes) in readEvents + notifyEvents {
                let out = m.handle(.notifyData(characteristic: u, data: bytes))
                pump(out)
                for a in out.actions {
                    if case .write(_, let d) = a { print("  write " + A6Hex.encode(d)) }
                    if case .disconnect = a { print("  disconnect") }
                }
            }
            print("final phase: \(m.phase)")
            print("records: \(records.count), live samples: \(live)")
            for r in records {
                print("  \(r.weightKg) kg (remain \(r.remainCount), impedance \(r.impedanceOhm.map(String.init) ?? "-"))")
            }
            return 0

        default:
            print("unknown capture kind '\(kindRaw)' (expected pair|session)")
            return 2
        }
    }
}
