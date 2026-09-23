# Yantra — Technical Design Document (TDD)

Version 1.0 · 2026-09-20 · Companion to SRD-000…SRD-007
Evidence base: `../analysis/PROTOCOL_ANALYSIS.md` (decompiled Lifesense stack) + live BLE capture (`../analysis/tools/ble_scan.swift`, 2026-09-20).

## 1. System overview

```
┌────────────────────────────────────────────────────────────────────────┐
│                            Yantra App (iOS/Android)                   │
│                                                                        │
│  ┌──────────┐   ┌───────────────────────┐   ┌──────────────────────┐   │
│  │ UI Layer │──▶│ Domain / Feature Layer │──▶│ Persistence Layer    │   │
│  │ SwiftUI/ │   │ - ScanViewModel        │   │ - SwiftData/Room DB  │   │
│  │ Compose  │   │ - PairViewModel        │   │   (Measurements,     │   │
│  │          │   │ - MeasureViewModel     │   │    BindRecords,      │   │
│  │          │   │ - HistoryViewModel     │   │    Profiles)         │   │
│  │          │   │ - BodyComposer         │   │ - Keychain/Keystore  │   │
│  └──────────┘   └───────────┬───────────┘   └──────────▲───────────┘   │
│                             │                          │               │
│                  ┌──────────▼───────────────────────────┴───────────┐   │
│                  │        ScaleKit (protocol module, no UI deps)    │   │
│                  │  ┌────────────┐ ┌────────────┐ ┌──────────────┐  │   │
│                  │  │ BleCentral │ │ FrameCodec │ │ A6Protocol   │  │   │
│                  │  │ (platform  │ │ (XOR/CRC32 │ │ (state mach. │  │   │
│                  │  │  adapter)  │ │  chunking) │ │  cmd encode/ │  │   │
│                  │  │            │ │            │ │  parse)      │  │   │
│                  │  └────────────┘ └────────────┘ └──────────────┘  │   │
│                  │  ┌────────────────────────────────────────────┐  │   │
│                  │  │ ScaleClient: scan→pair→session→sync façade │  │   │
│                  │  └────────────────────────────────────────────┘  │   │
│                  └───────────────────────┬──────────────────────────┘   │
└──────────────────────────────────────────┼──────────────────────────────┘
                                           │ BLE (GATT, service A602)
                                ┌──────────▼──────────┐
                                │ realme Smart Scale  │
                                │ (Lifesense LS213-B) │
                                └─────────────────────┘
   No cloud. No accounts. No network permission required for core features.
```

## 2. Module design

| Module | Responsibility | Key types |
|---|---|---|
| `ScaleKit` (framework/package, pure logic + platform port) | All A6-protocol logic; 100% unit-testable without hardware | `A6FrameCodec`, `A6Command`, `A6PacketAssembler`, `PairStateMachine`, `SessionStateMachine`, `WeightRecordParser` |
| `ScaleKitBle<Platform>` | Thin GATT adapter: scan/connect/notify/write; platform adapter interface `BleCentralPort` | `CoreBleCentral` (iOS), `AndroidBleCentral` |
| `Domain` | User profiles, measurements, body-composition math, unit conversion | `Measurement`, `UserProfile`, `BodyComposer`, `UnitConverter` |
| `Persistence` | Local encrypted store; export (CSV/HealthKit) behind explicit user action | `MeasurementStore`, `BindRecordStore` |
| `UI` | Views + view models only | per SRD flows |

**Dependency rule:** `UI → Domain → ScaleKit → BlePort` (interface). ScaleKit never touches platform APIs directly.

## 3. ScaleKit internals

### 3.1 Frame codec (port of `DeviceDataPackage` + `A6ProtocolParser`)

- **Encode (app→device)**: payload → optional XOR with MAC (fw ≥ "1.4.0.25") → append CRC32 if >1 frame → chunk to 18-byte frames → header byte `(count<<4)|serial`, length byte. Write to `A624`; ACK-carrying writes to `A622`.
- **Decode (device→app)**: notify from `A621` → parse header → XOR-decode → reassemble by serial → verify CRC (poly `0xEDB88320`, init 0, xorout 0 — **verified from decompiled table gen**) → classify by 2-byte command (`PacketProfile` map) → dispatch.
- **ACK**: `[00,01,status]`; status `1` ok / `2` fail.

### 3.2 Command queue

Single-flight queue per connection: send → await device ACK (`A625`/`A621` ACK frame) → next. 3 s resend timer, max 3 resends then error. Mirrors official `commandCacheQueue`.

### 3.3 Pair state machine (SRD-002)

Port of `FatScalePairWorker` flow with states: `CONNECT → DISCOVER → ENABLE_NOTIFY → READ_INFO → READ_FEATURE → REGISTER → AUTH → BIND_CONFIRM → DONE`. DeviceId = `verificationCode ⊕ MAC` (both from the wire; MAC obtained from advertisement manufacturer-data on iOS — see §6).

### 3.4 Session state machine (SRD-003/004/005)

`CONNECT → INIT_RESPONSE(0x000A) → PUSH_TIME(0x1002) → PUSH_PROFILE(0x1001) → PUSH_UNIT(0x1004) → [MEASURE_STREAM] → HISTORY_DRAIN(0x4802 until remainCount==0) → IDLE → DISCONNECT`.

## 4. Data model (local store)

```
UserProfile(id, name, sex, age, heightCm, athlete, activityLevel, unit, targetKg?, scaleSlot 0..4)
Measurement(id, profileId?, deviceId, utcEpoch, weightKg, impedanceOhm?, unitRaw, rawFlags,
            source: live|history, createdAt)
BindRecord(deviceKey, macString, peripheralIdentifier?, deviceId(12hex), slot, fwVersion,
           featureBitmap?, boundAt, lastSeenAt)
```

- `deviceKey` = MAC string from advertisement (stable across platforms, see §6).
- DB encrypted at rest (SQLCipher or platform default + file protection class).
- HealthKit/CSV export = explicit user action, records only, no profile sharing by default.

## 5. Body-composition module

`BodyComposer.compute(weightKg, impedanceOhm, profile) -> [metric: value]` — BMI, body-fat %, water %, muscle, fat-free, soft-lean, bone, visceral level, BMR. Formula set pluggable (`FormulaType` selection matches `0x1006` push). Golden tests: same inputs → same outputs as realme Link (validated in bring-up; tolerance ±0.1).

## 6. Empirical validation (live capture, 2026-09-20)

Captured with `analysis/tools/ble_scan.swift` (CoreBluetooth scan, 60 s):

| Field | Captured value | vs decompiled spec |
|---|---|---|
| Local name | `realme Smart Scale` | ✓ matches `bluetoothBroadcastName` |
| Advertised service | `A602` | ✓ matches `DEVICE_A6_SERVICE_UUID` |
| Advertising cadence | continuous ~10 Hz while awake, RSSI −56…−78 @ ~3 m | discovery <10 s feasible |
| Manufacturer data | `12 34 56 78 01 31 06 1b cb 0b d8` (11 B) | ✓ matches "len ≥ 11" gate |
| — company ID | `0x3412` (LE `12 34`, unassigned/custom) | custom, as expected for OEM |
| — manufactureId | `56 78` (bytes +2..+4) | ✓ `parseManufactureId` offset |
| — register-status | `01` (byte +4) | ✓ `parseRegisterStatus` offset |
| — device MAC | `31 06 1b cb 0b d8` (trailing 6 B) | ✓ = broadcastID convention (MAC no colons) |

**Consequence:** the scale broadcasts its own MAC in the clear → iOS can build the identical `deviceId = verificationCode ⊕ MAC` as Android and persist a stable cross-platform key. This closes the "iOS has no MAC" unknown.

## 7. Platform notes

- **iOS**: CoreBluetooth central; background scan not needed v1; `NSBluetoothAlwaysUsageDescription`; State Restoration for long history drains (v2).
- **Android**: `BLUETOOTH_SCAN`+`BLUETOOTH_CONNECT` (12+), location permission only ≤11; single foreground service for sync (user-initiated).
- **MTU**: protocol is 20-byte ATT-native (18 B payload frames); request larger MTU opportunistically but the official init caps at 20 (`WeightInitForA6.setMtu(20)` observed) — keep 20-byte framing regardless.

## 8. Testing strategy

| Layer | Method |
|---|---|
| FrameCodec | golden vectors captured from live device + decompiled logic ports; CRC property tests |
| State machines | injected fake `BlePort` replaying captured notify sequences |
| Parser | synthetic `0x4802` records with all flag combinations |
| BodyComposer | fixture-based vs official app readings |
| Integration | physical scale HIL script (macOS CLI harness reusing ScaleKit via a Swift host target) |
