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
- [x] **CLI host app built (`a6host`, `scalekit/Sources/A6Host/`):** CoreBluetooth central reusing ScaleKit — scan/pair/session/replay subcommands, verbatim notify logging into replay-format captures (`analysis/captures/README.md` schema), 3 s ACK-resend watchdog, read logging (180a fw + A641 feature), persist-then-retrieve peripheral flow (`scan` → `pair`/`session`), signal-safe capture save.
- [x] **E1 (direct, Mac→scale):** register `0x0001` correctly encoded and **ACKed**; scale replies `0x0002 = 1` ("already registered") — but **no `0x0007` challenge is ever sent to an unknown BLE peer**, with or without a weigh-in (attempts: skip-register, register-as-MAC, register-with-foreign-deviceId). Verdict: the scale only challenges identities it already knows; fresh pairing likely requires the official app's introduction (or GATT bond). U1 *as stated* ("auth is just code ⊕ MAC") is **confirmed for the login path** by the HCI capture below (response echoes the challenge, no secret) — the open question moved to *how a new host gets introduced*.
- [x] **E1′ (ground truth via official app):** captured the realme Link app's complete exchange with a rooted phone's **Bluetooth HCI snoop log** (`analysis/tools/hci_decode.py` decodes btsnoop → A6 transcript + replay capture). Decoded session (frames #433–476, #1325–1753): challenge `0x0007` (verification code **all-zeros**) → ACK → `0x0008` echo (mode 0 = login, ASCII-hex quirk confirmed on wire) → `0x0009` flags `0x18` → `0x000A` = **8 bytes only** `[0A 18 UTC4 tz1]` → `0x4801 00 01` (**slot 0-based**) → config pushes **`0x1001` user-info → `0x1004` unit → `0x1007` HR-switch** (each confirmed by `0x1000` callbacks; no time push, no clear-data push) → `0x4802` records with remain 43→0.
- [x] **Library corrections from hardware truth (all tests updated, 33/33 green):** `responseInit` trimmed to the 8-byte form; `measureSetting` slot 0-based; tz code = `(offsetMinutes/15)+48` (IST → `0x46`); config push set = user-info/unit/HR-switch; `0x1004`=PUSH_UNIT, `0x1005`=PUSH_CLEAR_DATA (decompiled PacketProfile).
- [x] **E2 (replay on real capture):** `a6host replay` on the HCI-derived capture (`analysis/captures/hci/session_realweighin.json`, 54 device→app events) drives `SessionStateMachine` to `.live` with **45 records parsed** (weight, remain counter, impedance) — the replay harness now runs on genuine wire data, closing the Phase 0 caveat.
- [x] **E1″ (pairing introduction SOLVED — Mac bound itself, 2026-09-21 13:40):** the gate was GATT-level, not protocol-level: the scale only challenges peers that subscribe **all four** notifiable characteristics — `A620` (READ\|INDICATE, CCCD 0x0002), `A621`, `A625`, `1531` (OTA channel) — discovered in phone-B's fresh-pairing btsnoop (br8: challenge fired ~1 ms after the 3rd/4th CCCD). With full subscribe set, the Mac's own flow completed: register `0x0001 [deviceId=MAC][state]` → `0x0002=1` → challenge `0x0007` → auth mode 1 (bind) → `0x0003` → `0x0004=1` **BOUND ✓** (deviceId `D80BCB1B0631`). No cloud, no secret, no BLE bonding (verified: zero SMP frames). deviceId = lowercase MAC confirmed via app logcat.
- [x] **E2″ (live weigh-ins on the Mac, 2026-09-21 14:26):** after the bind, the scale challenges the Mac **spontaneously on connect** (login mode 0 → init → `0x4801` → pushes, byte-parity with the phone). Weigh-ins stream as **real-time `0x4802` records** (wire `0x1011` obfuscated; remain 3→0, live impedance) — there is **no separate live-stream frame type** (U2 closed; `0x00E9` never appears). Records only flow when the app sends **`0x4801 [slot][1]` start-measurement** (phone parity; our `--arm` flag) after the handshake. Firmware read directly on the wire: **1.4.0.42** (XOR variant confirmed).
- Exit status: **protocol fully hardware-verified end-to-end from our own Swift stack** — bind, login, config, live weigh-in streaming, and post-measurement record pull, no official app involved. Phase 1 complete.

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
