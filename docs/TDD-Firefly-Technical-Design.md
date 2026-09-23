# Firefly — Technical Design Document (TDD)

Version 2.0 · 2026-09-23 · Companion to SRD-000…SRD-011
Evidence base: `../analysis/PROTOCOL_ANALYSIS.md` (decompiled Lifesense stack) + live BLE capture (`../analysis/tools/ble_scan.swift`, 2026-09-20).
Architecture: multi-device driver/registry model per SRD-009 (hub → drivers → shared transport).

## 1. System overview

```
┌────────────────────────────────────────────────────────────────────────┐
│                            Firefly App (iOS/Android)                   │
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
| `ScaleKit` (Swift package, pure logic) | All A6-protocol logic **+ the SRD-009 driver layer**: `DeviceDriver`/`DeviceScanner`/`DeviceSession`, `DriverRegistry`, per-kind drivers | `A6FrameCodec`, `A6Command`, `A6PacketAssembler`, `PairStateMachine`, `SessionStateMachine`, `WeightRecordParser`, `DeviceDriver`, `DriverRegistry`, `ScaleDriver`, `WatchDriver`, `BulbDriver`, `DfuStateMachine`, `BodyComposer`, `BodyCalibration` |
| `DeviceCore` (iOS app layer) | One shared `CBCentralManager` for every driver; normalizes CB callbacks into `CentralEvent`s; persistent device inventory | `DeviceTransport`, `TransportPeripheralDelegate`, `DeviceStore` (`devices.json`), `PairedDevice` |
| `Domain` (iOS) | User profiles, measurements, body-composition, export | `Person`, `MeasurementRecord`, `PersonStore`, `MeasurementStore`, `BindStore`, `ScaleConfigStore`, `HealthKitWriter`, `CSVExport` |
| `UI` (SwiftUI) | Devices hub (home) + per-driver feature views | `DevicesHubView`, `AddDeviceSheet`, `MainTabView` (scale tabs: Measure/History/Device), `CalibrationView`, `DfuView` |

**Dependency rule:** `UI → DeviceCore → ScaleKit` (interfaces only). ScaleKit has zero platform dependencies (`swift test` runs on macOS); CoreBluetooth types never cross into drivers — they are normalized into `AdvertisementSnapshot`/`CentralEvent` by `DeviceTransport`.

### 2.1 Adding a device kind (SRD-009 acceptance criterion 4)

1. Implement `DeviceDriver` (`kind`, `displayName`, `summary`, `makeScanner()`, `makeSession()`).
2. Register it in `FireflyDrivers.registry` (`DevicesHubView.swift`) — one line.
3. Add the driver's feature views; route them in `driverDestination`.

No edits to the hub, transport, or any other driver.

## 3. ScaleKit internals — scale protocol (SRD-001…008)

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
Person(id, name, sexMale, age, heightCm, targetWeightKg?, preferredSlot, isActive, isMe)
MeasurementRecord(id, deviceId, slot, weightKg, impedanceOhm?, utc, unitRaw, rawFlags,
                  source: live|drain, personId?)
BindRecord(mac, deviceId(12hex), peripheralId?, slot, fwVersion, featureBitmap?, boundAt)
PairedDevice(peripheralId, kind, name, addedAt)   // devices.json — SRD-009 inventory
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

- **iOS**: one CoreBluetooth central (`DeviceTransport`) shared by all drivers; per-driver flows keep their own pipelines (`ScaleCentral` is wire-verified and intentionally self-contained — SRD-009 FR-5); `NSBluetoothAlwaysUsageDescription`; State Restoration for long history drains (v2).
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
