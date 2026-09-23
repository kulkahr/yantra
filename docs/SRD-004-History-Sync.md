# SRD-004 — Measurement History Sync

Parent: SRD-000 · Priority P1 · Protocol source: `DeviceSyncCentre`, `DataParseUtils.parseWeightDataForA6`, `PacketProfile.PUSH_CLEAR_DATA_TO_WEIGHT_FOR_A6`

## 1. Purpose

Drain measurements the scale stored in its own memory (weigh-ins performed while no phone was connected) into Yantra's local history, and optionally clear scale memory.

## 2. How sync is triggered

- Every connect, the scale reports `remainCount` in each `0x4802` record header and in `0x00E9` records — the count of stored-but-not-yet-drained measurements.
- `DeviceSyncCentre` drives the drain: read record → ACK → next, until `remainCount == 0`.

## 3. Record layout (`0x4802` DEVICE_A6_WEIGHT_DATA)

After the 2-byte command header:

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | remainCount |
| 2 | 4 | flags bitfield |
| 6 | 2 | **weight ×100** (kg) |
| +optional (in flag order) | | userId(1), UTC(4), tz(1), datetime(7: y2 m d h min s), BMI(2), fat-ratio(2), basal-met(2), muscle-ratio(2), muscle(2), fat-free(2), soft-lean(2), water-ratio(2), **impedance Ω(2)** |

Flags: bits 0–1 unit; bit 2 userId; bit 3 UTC; bit 4 tz; bit 5 datetime; bits 6–14 field-presence bits as listed.

## 4. Requirements

| ID | Requirement |
|---|---|
| FR-1 | App SHALL parse records exactly per §3, honoring presence bits (variable-length payload). |
| FR-2 | App SHALL ACK each record and continue until `remainCount == 0`. |
| FR-3 | App SHALL deduplicate stored records by (deviceId, UTC, weight) — official app keeps records in local DB (`WeightDataDbManager`) with the same keying. |
| FR-4 | App SHALL offer explicit "clear scale memory" (`0x1005` [userSlot][timestamp]) with confirmation; default is to keep scale memory. |
| FR-5 | App SHALL render history: list + trend chart (weight; BMI/fat% computed per SRD-006 when impedance present). |
| FR-6 | App SHALL export history to Apple Health / CSV on explicit user action only (privacy default: off). |
| FR-7 | App SHALL survive interruptions: resume drain on next connect (scale re-reports remainCount). |

## 5. Acceptance criteria

1. Weigh 3 times offline (Bluetooth off on phone) → on reconnect, 3 records appear with correct UTC timestamps and values.
2. Duplicates never appear in the list after repeated connects.
3. Clear-memory removes all stored records from the scale and is reflected in subsequent remainCount = 0.
4. CSV/HealthKit export contains identical values to the app list.
