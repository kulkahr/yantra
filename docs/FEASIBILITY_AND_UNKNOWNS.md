# Firefly — Feasibility, Blockers & Unknowns (re-verified 2026-09-20)

Verdict: **FEASIBLE — no hard blockers.** Every critical protocol fact has been confirmed twice (decompiled source + live BLE capture). Three residual unknowns remain, each with a bounded mitigation and a concrete experiment.

## 1. Verification matrix

| # | Question | Method | Result |
|---|---|---|---|
| 1 | Is the scale a standard BLE peripheral reachable from any host? | Live CoreBluetooth scan from Mac | ✅ YES — advertises `A602` + name `realme Smart Scale`, connectable-looking, no allow-list visible |
| 2 | Does the protocol need realme cloud/account? | Decompiled pair/sync workers (`FatScalePairWorker`, `FatScaleWorker`) | ✅ NO — fully device-local handshake; cloud only used by the official app after bind |
| 3 | Are frame formats/commands fully decoded? | Decompiled codec + parsers | ✅ YES — headers, XOR variant gate, CRC32 poly/init/xorout, command set 0x0001–0x4802, `0x4802` TLV layout |
| 4 | Can iOS derive the same deviceId as Android? | Live capture: manufacturer data contains full MAC (`31:06:1b:cb:0b:d8`); deviceId = `code ⊕ MAC` | ✅ YES — both inputs available on iOS |
| 5 | Does the scale work with the official iOS app? | App Store listing/reviews + absence of scale module in iOS build | ❌ NO — realme never shipped the module (not a hardware limit) |
| 6 | Is connection stable enough for measurements? | Observed continuous ~10 Hz advertising, RSSI −56…−78 @ 3 m | ✅ Adequate; real test in HIL phase |
| 7 | Does anything block App Store distribution? | CoreBluetooth usage review | ✅ NO proprietary-SDK/MFi requirement; standard BLE central app |

## 2. Remaining unknowns & mitigations

| # | Unknown | Risk | Mitigation / experiment |
|---|---|---|---|
| U1 | ~~Whether the scale enforces an app-side *challenge secret*~~ **FULLY RESOLVED (2026-09-21):** auth is secret-free — challenge code is all-zeros, app echoes it. The **pairing introduction is solved too**: the scale gates its challenge on the peer subscribing all four notifiable characteristics (`A620` indicate + `A621` + `A625` + `1531`); with those CCCDs set, the Mac registered and **bound itself** (auth mode 1 → `0x0003` → `0x0004=1`), no cloud, no secret, no BLE bonding. deviceId = lowercase MAC. |
| U2 | ~~Exact live-weight stream frame type~~ **RESOLVED (2026-09-21, Mac live session):** there is **no separate live frame** — weigh-ins stream as real-time `0x4802` records (obfuscated `0x1011` on the wire; remain counter ticks down to 0, impedance updates during the body scan). Records flow only after the client sends `0x4801 [slot][1]` (start-measurement). `0x00E9` never appears on this firmware. |
| U3 | Body-fat formula constants (Lifesense S11 set) | UI parity for computed metrics | Raw weight+impedance are unaffected. Formula approximated first, tuned in bring-up vs official app readings (±0.1 tolerance). Optionally capture official app traffic on Android via HCI snoop to extract exact math. |
| U4 | Multi-user slot contention with realme Link (same physical scale bound by both apps) | If user reinstalls official app, slot collisions possible | Documented behavior: scale keeps 5 slots; Firefly uses its own slot; SRD-002 FR-3 unbind path available. |
| U5 | Firmware variance across LS213-B units (XOR gate threshold "1.4.0.25") | Low — code supports both variants; live unit answers per ≥1.4.0.25 path | Codec implements both; feature-detect via `180a:2a26` firmware read. |

## 3. Blockers

None identified. The only hard dependency is **physical access to the scale for the HIL bring-up phase** (E1/E2), which we already have.

## 4. Legal/ethical re-check

- Interop research for personal use of one's own device: decompiled artifacts stay in this repo, are not redistributed (README note), and Firefly ships no realme/Lifesense code — only protocol behavior re-implemented from observation.
- No DMCA-relevant circumvention: no encryption is broken; the "obfuscation" is a documented XOR with a public identifier, and the auth exchange is echoed device-provided data.

## 5. Decision

Proceed to Phase 0 of the roadmap (`FUTURE_PLAN.md`) — build `ScaleKit` + E1 macOS handshake harness first, since E1 converts the last protocol-level unknown into a verified fact before any mobile UI work starts.
