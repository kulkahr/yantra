# SRD-003 — Real-Time Weight Measurement

Parent: SRD-000 · Priority P0 · Protocol source: `FatScaleWorker`, `DeviceSyncCentre`, `DataParseUtils.parsingNewMeasureData`, `PacketProfile`

## 1. Purpose

Show live weight while the user stands on the scale, and capture the stabilized final measurement as a record.

## 2. Preconditions

- Valid bind record (SRD-002) or the user accepts open-session mode (connect + register each time).
- Scale connected; notifies enabled on `A621`/`A625`.

## 3. Session setup commands (sent after each connect)

| Command | Payload | Purpose |
|---|---|---|
| `0x000A` RESPONSE_INIT | capability bitmap echo (+MTU, UTC, timezone, timestamp) | respond to scale's `0x0009` init request |
| `0x1002` PUSH_TIME | flags + UTC(4B) + tz(1B) + datetime(7B) | keep scale clock correct so stored records carry right timestamps |
| `0x1001` PUSH_USER_INFO | slot, sex, age, height×100, athlete, activity, weight×100 | feed body-fat math |
| `0x1004` PUSH_UNIT | unit byte (0 kg / 1 lb / 2 st / 3 jin) | display unit on scale LED |
| `0x4801` MEASURE_SETTING | [userSlot][on=1] | arm measurement for a slot (official start-measure) |

## 4. Live data

- Live weight frames arrive during measurement (`REAL_TIME_MEASURE_DATA` / `NEW_MEASURE_DATA 0x00E9` paths; `0x00E9` carries UTC, delta-UTC, remain-count and g-sensor/heart-rate/step blocks).
- Final record arrives as `0x4802` (see SRD-004 layout) with flags selecting included fields (weight, user, UTC, impedance…).

## 5. Requirements

| ID | Requirement |
|---|---|
| FR-1 | App SHALL stream live weight to UI with ≤ 300 ms render latency after notify. |
| FR-2 | App SHALL detect measurement stabilization (official: final record push; app additionally treats 2 s of identical readings as stable fallback) and mark "final". |
| FR-3 | App SHALL parse `0x4802` records per the §6 layout and store them locally. |
| FR-4 | App SHALL push time + user info + unit at session start (required by scale for correct timestamps/body-fat). |
| FR-5 | App SHALL support kg/lb/st/jin display conversions and remember user preference. |
| FR-6 | App SHALL warn if weight > scale max (official S11 max 180 kg) or unstable footing (impedance absent / measurement-flag bits). |
| FR-7 | App SHALL handle multiple rapid step-on/off cycles without leaking GATT connections (single worker queue). |
| FR-8 | App SHALL work with the scale in guest mode (no user push) — weight-only measurements always visible. |

## 6. Acceptance criteria

1. Step on scale → live number tracks movement within 0.3 s.
2. Step off → final record saved with weight (2 decimals, kg), timestamp from scale (UTC), user slot, and impedance when the user is barefoot and profile pushed.
3. Weight in Firefly matches scale LED and official realme Link reading ±0.05 kg.
4. Airplane-mode scale → app shows reconnect state per NFR-5 constants and recovers automatically when scale returns.

## 7. Privacy requirements

- No measurement leaves the device; no cloud fallback; no backup of raw health data in unencrypted exports (local DB encrypted with device keychain/keystore key).
