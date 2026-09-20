# Firefly — Future Plan & Roadmap

Baseline: SRD-000…007, TDD, DIAGRAMS, FEASIBILITY_AND_UNKNOWNS (2026-09-20).

## Phase 0 — Protocol library & offline tests (week 1–2)
- [ ] Swift package `ScaleKit` (portable core): frame codec, CRC32 (`0xEDB88320`, init 0, xorout 0), XOR-MAC variant gate, packet assembler, command encoders (`0x0001`–`0x1007`), `0x4802` record parser with all flag combinations.
- [ ] Golden-vector tests from captured frames + decompiler-derived truth.
- [ ] Fake `BlePort` replay harness (recorded notify sequences drive state machines).
- Exit: 100% of codec/parser unit tests green without hardware.

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
