# SRD-000 — Firefly: Privacy-First Smart Device Hub — Overview

Version 2.0 · 2026-09-23 · Status: IMPLEMENTED (scale complete; multi-device core per SRD-009)
Companion analysis: `../analysis/PROTOCOL_ANALYSIS.md`, `../analysis/IOS_COMPATIBILITY_RESEARCH.md`

## 1. Vision

**Firefly** is a privacy-first mobile hub that talks *directly* to smart devices over BLE. It started as a replacement for realme Link's smart-scale module (Lifesense LS213-B) for people who do not want an account, a cloud, or telemetry: measurements live on the phone (and only there, unless the user opts into Apple Health export). Per **SRD-009**, the app is now structured as a **multi-device hub** — the scale is the first fully-implemented driver, with smart-watch (SRD-010, planned) and smart-bulb (SRD-011, planned) drivers following the same architecture.

## 2. Why this is possible (evidence)

- The scale's entire protocol was extracted from the official app's dynamic feature module and specified in `PROTOCOL_ANALYSIS.md`: GATT service `A602`, frame codec, pairing/auth state machine, weight-record format.
- The protocol uses no cloud, no account, no server-side component. Binding is a device-local handshake.
- BLE is platform-neutral → an iOS implementation is feasible (see iOS research: the official iOS app simply lacks the module).
- The SRD-009 driver/registry architecture keeps every future device kind behind the same hub, transport and privacy model.

## 3. Scope

| In scope | Out of scope |
|---|---|
| Multi-device hub: scale (now), watch/bulb (SRD-010/011, planned) | realme Link full IoT suite replacement |
| Scan/discover, pair/bind/unbind with the scale | realme cloud APIs, account login |
| Real-time weight, history sync, scale configuration | Any cloud-hosted feature |
| Battery + device info, computed body composition, calibration | Multi-radio (WiFi/Thread) devices |
| DFU firmware update with user-supplied images | Producing/hosting firmware |
| Local persistence + opt-in Apple Health export (owner profile only) | |

## 4. Functional feature set (SRD index)

| SRD | Feature | Priority | Status |
|---|---|---|---|
| SRD-001 | Device discovery & scan | P0 | Implemented |
| SRD-002 | Pairing, binding & authentication | P0 | Implemented |
| SRD-003 | Real-time weight measurement | P0 | Implemented |
| SRD-004 | Measurement history sync (+clear-memory, per-record assign/delete) | P1 | Implemented |
| SRD-005 | Scale configuration (time, unit, user, target, formula, echo verify) | P1 | Implemented |
| SRD-006 | Device info, battery & body-composition (+official-app calibration) | P1 | Implemented |
| SRD-007 | Firmware update (DFU) client support | P2 | Implemented |
| SRD-008 | Multi-person weight assignment | P1 | Implemented |
| SRD-009 | Multi-device architecture (hub, drivers, registry) | P1 | Implemented (core + scale; watch/bulb stubs) |
| SRD-010 | Smart-watch integration (placeholder — completed when a target watch is chosen) | P2 | Planned — [SRD-010](SRD-010-Watch-Integration.md) |
| SRD-011 | Smart-bulb integration (placeholder — completed when a target bulb is chosen) | P2 | Planned — [SRD-011](SRD-011-Bulb-Integration.md) |

## 5. Non-functional requirements

| ID | Requirement |
|---|---|
| NFR-1 | **Privacy**: zero network permissions for core features; all data local; no analytics, no crash reporting, no tracking SDKs. HealthKit export strictly opt-in per record or per dataset. |
| NFR-2 | **Transparency**: show raw parsed measurement values (weight, impedance) and computed values separately. |
| NFR-3 | **Openness**: protocol implementation isolated as a testable module; golden-vector unit tests from captured frames. |
| NFR-4 | **Platforms**: iOS 17+ (CoreBluetooth, shipping today — the iOS app is the reference implementation); Android 8+ (BLE API) is the follow-on target for the same protocol module — not started. |
| NFR-5 | **Reliability**: port official timeouts — 3 s command resend, 2 reconnect attempts, 180 s pair window. |
| NFR-6 | **Security posture**: no BLE bonding required; app must handle unencrypted link (no secrets stored); deviceId derivation is deterministic (`verificationCode XOR MAC`) and never stored outside the bind record. |

## 6. Assumptions

- Scale firmware is the current shipping LS213-B generation supporting A6 protocol with `Security.code` "1.4.0.25" behavior (XOR obfuscation active for fw ≥ 1.4.0.25; both variants supported).
- One scale, up to 5 user slots (GUEST + USER1–4); Firefly occupies one slot.
- Body-composition formulas are computed client-side from weight + impedance + user profile.
