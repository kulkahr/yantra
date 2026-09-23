# SRD-010 — Smart-Watch Integration

Parent: SRD-000 · Priority P2 · Status: PLANNED (stub driver shipped per SRD-009 FR-6)
Driver: `WatchDriver` (`scalekit/Sources/ScaleKit/Drivers.swift`) — scanner + session skeleton, `isStub = true`

## 1. Purpose

Bring health/fitness watches into the Firefly hub under the same privacy model as the scale: data flows device → phone over BLE and stays local unless the user opts into Apple Health export. No vendor cloud, no accounts.

## 2. Why a placeholder SRD (not implemented yet)

Watches do not have one protocol — they have dozens. The realistic families:

| Family | Transport | Examples | Effort |
|---|---|---|---|
| Standard GATT services | BLE GATT: BPS (`0x1810`), HRS (`0x180D`), battery `0x180F` | Any watch exposing standard profiles | Low |
| Vendor notification protocol | Vendor service (e.g. Huami `0xFE95`, Zepp, Realme Watch `0xF000`-ish) | realme Watch, Mi Band, Haylou | High (reverse-engineering) |
| Companion-required | Pairs only through the vendor app first; data resyncs from cloud | Apple Watch (HealthKit instead), wearOS | Out of scope for BLE-direct |

**Decision gate:** SRD-010 is completed only after a physical target watch is chosen. The first implementation step is a BLE capture (`analysis/tools/ble_scan.swift` pattern + nRF Capture) of the watch's advertisement, GATT layout, and an authenticated command exchange — exactly the methodology that produced `PROTOCOL_ANALYSIS.md` for the scale.

## 3. Scope (what Firefly wants from a watch)

| Priority | Data / control | Notes |
|---|---|---|
| P1 | Heart-rate samples (HRS `0x2A37`) | Real-time + periodic |
| P1 | Step count / activity | Usually vendor service; standard FDMS `0x1069`/`0x106B` if supported |
| P2 | Sleep sessions | Vendor service — decode from capture |
| P2 | Watch face time sync (`0x2A2B`) | Official time service, low risk |
| P3 | Notifications from phone → watch | ANCS/AMS or vendor; privacy-sensitive — default off |

## 4. Requirements (pre-drafted, to be confirmed against the target device)

| ID | Requirement |
|---|---|
| FR-1 | The watch SHALL appear in the Devices hub via `WatchDriver` scan (name prefixes + standard GATT probe) and pair without any vendor account. |
| FR-2 | Health data SHALL be stored locally in Firefly's store; export to Apple Health only via the existing opt-in owner-profile flow (issue #14 model). |
| FR-3 | Watch data SHALL NOT be mixed into the scale's weight-history attribution (SRD-008); watch records carry their own device id and are shown under the watch driver's view. |
| FR-4 | Authentication (if the vendor protocol requires it) SHALL be ported verbatim from a decompiled vendor app or captured session, and documented in this SRD with golden vectors. |
| FR-5 | Battery + firmware of the watch SHALL surface in its driver page (SRD-006 parity). |

## 5. Acceptance criteria

1. Chosen watch appears in the hub, connects, and shows live heart rate (standard HRS path) with zero cloud involvement.
2. Steps/heart-rate history syncs into local storage and is visible/exportable per the privacy rules.
3. All protocol knowledge is documented here (frame maps, golden vectors) the way `PROTOCOL_ANALYSIS.md` did for the scale.
