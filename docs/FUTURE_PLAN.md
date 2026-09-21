# Firefly — Future Plan & Roadmap

Baseline: SRD-000…007, TDD, DIAGRAMS, FEASIBILITY_AND_UNKNOWNS (2026-09-20).

## Phase 0 — Protocol library & offline tests (week 1–2)
- [x] Swift package `ScaleKit` (`scalekit/`): CRC32 (`0xEDB88320`/init 0/xorout 0), XOR-MAC variant gate, frame codec + packet assembler, command builders (register/auth/bind/unbind/ACK/init/time/user-info/unit/target/clear), deviceId derivation, `0x4802` weight-record parser with flag handling.
- [x] Golden-vector tests (12/12 green) from `analysis/tools/golden_gen.py` truth model (`analysis/tools/golden_vectors.json`), incl. direction-correct round-trips and CRC-corruption rejection.
- [x] **Protocol correction found by tests:** device→app wire format is `xor(plaintext ‖ crc32(plaintext))`; CRC is computed over plaintext and is itself obfuscated with the rest of the stream (PROTOCOL_ANALYSIS §3 updated). app→device commands are always single-frame (≤18 B), so no CRC occurs in that direction.
- [x] **State machines (pair/session) as code + replay tests (27/27 green):** `PairStateMachine` (connect → device-info/feature → register `0x0001` → challenge `0x0007` → auth `0x0008` → bind confirm `0x0003/0x0004` → disconnect; rejection/refusal/timeout/resend-exhaustion paths), `SessionStateMachine` (connect → notify → init `0x0009→0x000A` → config flush `0x1002/0x1001/0x1004` → live `0x00E9` → `0x4802` drain by `remainCount` → finish), `CommandQueue` (single-flight, ACK-pop, 3× resend), and a firmware-accurate `DeviceSimulator` (wire-level replay incl. XOR + plaintext-CRC packets).
- [x] **Recorded-session replay harness (Phase 0 leftover):** `BleReplayPlayer` (test target) replays *recorded* device→app notify sequences verbatim against `PairStateMachine`/`SessionStateMachine`; capture format v1 documented in `analysis/captures/README.md`. Synthetic reference capture (`synthetic_session_capture.json`, wire bytes generated from `DeviceSimulator` semantics) + 5 replay tests prove the harness end-to-end (32/32 green). **Caveat:** synthetic captures only prove the harness — they cannot falsify wire assumptions. Real pair/weigh-in captures (experiments E1/E2, Phase 1) are the actual falsification step and drop straight into the same harness.
- How to run tests on this machine: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` from `scalekit/` (the default `xcode-select` target is CommandLineTools, which lacks the XCTest module).
- Exit: state machines green in replay; codec/parser already 100% green without hardware.

## Phase 1 — macOS handshake harness (Experiments E1 + E2) (week 2–3)
- [ ] CLI host app reusing ScaleKit + CoreBleCentral: scan → connect → register → auth → bind (E1).
- [ ] Log all `A621` notifies during a real weigh-in; classify live-stream frame types (E2).
- [ ] Drain history; verify `remainCount` semantics and dedupe keys.
- Exit: E1 = successful bind from Mac; E2 = stream frame map documented in PROTOCOL_ANALYSIS appendix.
- Go/No-Go: if E1 fails on auth → capture official Android HCI snoop log, diff frames, update codec (bounded 1–2 day detour; protocol already fully decoded so risk is low).

## Phase 2 — iOS app skeleton (week 3–5)
- [ ] CoreBleCentral adapter + permissions; foreground scan/connect (SRD-001).
- [ ] Pair/bind UI + slot management (SRD-002).
- [ ] Measure screen: live weight, final record, local store (SRD-003).
- Exit: weigh-in end-to-end on iPhone, data stored locally.

## Phase 3 — History, profiles, body composition (week 5–7)
- [ ] History drain + list + trend chart (SRD-004).
- [ ] Profile management + config pushes incl. unit/time sync (SRD-005).
- [ ] BodyComposer v1 (formula approximation; tune vs official readings) (SRD-006).
- [ ] CSV export; HealthKit write (opt-in) (SRD-004 FR-6).
- Exit: parity test vs realme Link within tolerance.

## Phase 4 — Polish & release (week 7–9)
- [ ] Reconnect policy, error UX, low battery, DFU-mode detection (SRD-007 FR-1 only).
- [ ] Privacy review: zero network entitlements audit, Data Minimization section for App Store privacy labels.
- [ ] TestFlight → App Store submission.
- Exit: public v1.0 (iOS).

## Phase 5 — Android + ecosystem (later)
- [ ] Android port (same ScaleKit core, AndroidBleCentral adapter).
- [ ] Optional: widget, complications, multiple scales, webhook/bridge mode (Path C relay for smart-home integrations).
- [ ] Community: publish protocol spec + open-source ScaleKit under permissive license (docs only — no realme code).

## Standing risks → owners
| Risk | Mitigation owner |
|---|---|
| Firmware update changes protocol | Version-gate via `180a:2a26`; re-run E1 after scale OTA (SRD-007) |
| Body-fat accuracy complaints | Formula tuning loop vs official app; publish raw+computed separately (NFR-2) |
| Slot conflicts with official app | Docs + unbind flow (SRD-002 FR-3) |

## Immediate next action
Start Phase 0: scaffold `ScaleKit` Swift package with codec + CRC tests (the CRC and frame layout are already final from the decompiled source, so tests can be written today).
