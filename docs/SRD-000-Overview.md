# SRD-000 — Firefly: Privacy-First Smart Scale Client — Overview

Version 1.0 · 2026-09-20 · Status: DRAFT
Companion analysis: `../analysis/PROTOCOL_ANALYSIS.md`, `../analysis/IOS_COMPATIBILITY_RESEARCH.md`

## 1. Vision

**Firefly** is a privacy-first mobile app that talks *directly* to the realme Smart Scale (Lifesense LS213-B) over BLE. It replaces realme Link for scale owners who do not want an account, a cloud, or telemetry: measurements live on the phone (and only there, unless the user opts into HealthKit/Apple Health export).

## 2. Why this is possible (evidence)

- The scale's entire protocol was extracted from the official app's dynamic feature module and specified in `PROTOCOL_ANALYSIS.md`: GATT service `A602`, frame codec, pairing/auth state machine, weight-record format.
- The protocol uses no cloud, no account, no server-side component. Binding is a device-local handshake.
- BLE is platform-neutral → an iOS implementation is feasible (see iOS research: the official iOS app simply lacks the module).

## 3. Scope

| In scope | Out of scope |
|---|---|
| Scan/discover realme Smart Scale | realme Link app replacement (full IoT suite) |
| Pair/bind/unbind with scale | realme cloud APIs, account login |
| Real-time weight during measurement | Band/watch/headset features |
| Stored-measurement history sync | OTA firmware hosting (client support only, SRD-007) |
| Scale configuration (time/unit/user/target) | Multi-scale fleets > 1 concurrent device |
| Battery + device info, raw body-composition data | |
| Local persistence + optional HealthKit export | |

## 4. Functional feature set (SRD index)

| SRD | Feature | Priority |
|---|---|---|
| SRD-001 | Device discovery & scan | P0 |
| SRD-002 | Pairing, binding & authentication | P0 |
| SRD-003 | Real-time weight measurement | P0 |
| SRD-004 | Measurement history sync | P1 |
| SRD-005 | Scale configuration (time, unit, user, target, formula) | P1 |
| SRD-006 | Device info, battery & body-composition computation | P1 |
| SRD-007 | Firmware update (DFU) client support | P2 |

## 5. Non-functional requirements

| ID | Requirement |
|---|---|
| NFR-1 | **Privacy**: zero network permissions for core features; all data local; no analytics, no crash reporting, no tracking SDKs. HealthKit export strictly opt-in per record or per dataset. |
| NFR-2 | **Transparency**: show raw parsed measurement values (weight, impedance) and computed values separately. |
| NFR-3 | **Openness**: protocol implementation isolated as a testable module; golden-vector unit tests from captured frames. |
| NFR-4 | **Platforms**: iOS 15+ (CoreBluetooth) and Android 8+ (BLE API); identical protocol module. |
| NFR-5 | **Reliability**: port official timeouts — 3 s command resend, 2 reconnect attempts, 180 s pair window. |
| NFR-6 | **Security posture**: no BLE bonding required; app must handle unencrypted link (no secrets stored); deviceId derivation is deterministic (`verificationCode XOR MAC`) and never stored outside the bind record. |

## 6. Assumptions

- Scale firmware is the current shipping LS213-B generation supporting A6 protocol with `Security.code` "1.4.0.25" behavior (XOR obfuscation active for fw ≥ 1.4.0.25; both variants supported).
- One scale, up to 5 user slots (GUEST + USER1–4); Firefly occupies one slot.
- Body-composition formulas are computed client-side from weight + impedance + user profile.
