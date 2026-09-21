# realme-scale-re — Realme Smart Scale Protocol Research

Reverse-engineering workspace for the **realme Link** Android app (v5.5.514.11421, versionCode 530121), pulled from a Samsung Galaxy S23 FE (SM-S711B) on 2026-09-20, with the goal of building a **privacy-friendly app ("Firefly") that connects to the realme Smart Scale and reads weight data directly** — no realme cloud, no account.

## Key finding

> The **realme Smart Scale** is an OEM'd **Lifesense (乐心) Body Fat Scale S11, model `LS213-B`**.
> All of its BLE logic lives in `split_realmeSmartScale.apk` as a Lifesense SDK ("A6 protocol"), which was fully decompiled and is analyzed in this repo.

## Folder layout

| Path | Contents |
|---|---|
| `apk/` | All 25 pulled APK splits (base + dynamic feature modules) |
| `decompiled/smartscale/` | jadx output of `split_realmeSmartScale.apk` — **the scale BLE stack (950 classes, `com.lifesense.ble.*`)** |
| `decompiled/base/` | jadx output of `base.apk` (22,326 classes — app shell, account, cloud glue) |
| `analysis/` | Protocol + app-architecture + iOS-compatibility analysis |
| `analysis/tools/` | Live BLE scanner (Swift), Python codec truth model (`golden_gen.py`) + golden vectors |
| `scalekit/` | **ScaleKit** — Swift package implementing the A6 protocol (codec, commands, parsers, state machines, BodyComposer), 40/40 tests green |
| `ios/` | **Firefly** — SwiftUI iOS app (Phase 2/3): scan/bind (SRD-002), live weigh-ins (SRD-003), history + charts (SRD-004), profile + body composition (SRD-005/006), CSV/HealthKit export |
| `docs/` | SRDs (one per feature), TDD, diagrams, feasibility, roadmap |

## Documents

1. `analysis/PROTOCOL_ANALYSIS.md` — complete "A6" BLE protocol specification (GATT UUIDs, frame format, commands, pairing state machine, weight payload layouts)
2. `analysis/REALME_LINK_APP_ANALYSIS.md` — how realme Link works, data flows, privacy observations
3. `analysis/IOS_COMPATIBILITY_RESEARCH.md` — why the scale doesn't work on iPhone and how to fix it
4. `docs/SRD-000-Overview.md` … `docs/SRD-007-Firmware-Update.md` — Software Requirements Documents, one per feature

## Reproduction steps

> **Hardware-verified runbook: `REPLICATION.md`** — exact `a6host` commands to bind
> a fresh scale and stream weigh-ins from the Mac (no realme app, no cloud).

```bash
# 1. Enable USB debugging on the phone, then:
adb devices                              # verify device
adb shell pm path com.realme.link        # list split APK paths
adb pull <path> apk/<name>               # pull each split

# 2. Decompile
jadx -d decompiled/smartscale apk/split_realmeSmartScale.apk
jadx --no-res -d decompiled/base apk/base.apk
```

## Legal note

The decompiled code in `decompiled/` is **for personal interoperability research only** — to let the owner of a realme Smart Scale read their own weight data on the platform of their choice. Do not redistribute realme/Lifesense code, resources, or assets. The SRD documents describe *behavior and protocol*, and were written from scratch.
