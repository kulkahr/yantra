# SRD-010 — Smart-Watch Integration (boAt Storm Call 3)

Parent: SRD-000 · Priority P2 · Status: **IMPLEMENTED (live data, sleep/SpO2 history, persistence)**
Driver: `WatchDriver` (`scalekit/Sources/ScaleKit/Drivers.swift`), protocol: `KahaProtocol` (`scalekit/Sources/ScaleKit/KahaProtocol.swift`), app session: `WatchCentral` (`ios/Yantra/WatchCentral.swift`), storage: `WatchStore` (`ios/Yantra/WatchStore.swift`)

## 1. Purpose

Bring the **boAt Storm Call 3** (`stormcall_3_0610`) into the Yantra hub under the SRD-000 privacy model: health data flows watch → phone over BLE and stays local. No boAt/Cove cloud, no Crest account, no telemetry.

## 2. Target device & protocol provenance

| Fact | Value |
|---|---|
| Device | boAt Storm Call 3, advertised name `stormcall_3_0610` (prefix `stormcall_`) |
| Companion app | boAt Crest (`com.coveiot.android.boat`) — APK pulled from the user's Redmi Note 5 Pro, jadx-decompiled to `decompiled/boat/` |
| SDK stack | `StormCall3BleApiImpl` → `TFTStormCall2BleApiImpl` → `LeonardoBleApiImpl` / `LeonardoBleCmdService` (Cove "Leonardo" abstraction) over the **KaHa Pte** watch SDK (`com.coveiot.android.bleabstract.FitCloudSDKInit`, feature flag `setKaHaRealtekChip(true)` — Realtek chip, BT-calling platform) |
| Vendor cloud | Cove/boAt servers — bypassed entirely; nothing in the BLE protocol requires them |

The Storm Call 3 is one of ~150 device types sharing the KaHa "Leonardo" command set in Crest; the device-specific differences are feature flags only, not a different wire format.

## 3. Transport (GATT)

Nordic-UART-style private service (decompiled `BleUUID.java`):

| UUID | Role |
|---|---|
| `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | UART service |
| `6E400002-…` | Write characteristic (app → watch), write-with-response |
| `6E400003-…` | Notify characteristic (watch → app), CCCD `0x2902` |
| `0x180F` / `0x2A19` | Standard battery service/level |
| `0x180A` / `0x2A26` | Device information / firmware revision string |

Scan filter: name prefix `stormcall` (case-insensitive). `DeviceTransport` scans without service filters, drivers classify.

## 4. Frame format (verified against `BleUUID` constants + `ProtocolParser` dispatch)

```
offset 0    : classId  (byte)  — command class
offset 1    : cmdId    (byte)  — command within the class
offset 2..3 : payloadLen (uint16 LE)
offset 4..  : payload  (payloadLen bytes)
```

No checksum, no sequence numbers, no session/auth handshake — the link is usable immediately after GATT connect + CCCD subscription (contrast with the scale's A6 auth machine, SRD-002).

**Commands (app → watch)** use class id = request id; **responses/pushes (watch → app)** arrive with class id = `requestId + 0x80` (except `0x7F` multipacket continuation and the `0x06` live-data class which keeps `0x06` in both directions).

## 5. Command map (implemented)

| Class | Cmd | Name | Payload |
|---|---|---|---|
| `0x00` | `0x00` | Get device name | — |
| `0x00` | `0x01` | Get hardware version | — |
| `0x00` | `0x02` | Get firmware version | — |
| `0x00` | `0x06` | Get device time | — |
| `0x00` | `0x08` | Get battery level | — |
| `0x00` | `0x79` | Set 24-hour format | `00` |
| `0x00` | `0x81` | Set device time | yyyy(2 BCD) MM dd HH mm ss ±HH mm (10 B) |
| `0x01` | `0x02` | HR/BP auto-measure interval (set) | `minutes uint16 LE` |
| `0x01` | `0x02` | HR/BP history request | `day startHour endHour` (day = days ago, 0 = today) |
| `0x01` | `0x08` | **10-min sleep history** | `day startHour endHour` |
| `0x01` | `0x26` | **Periodic SpO2 history** | `day startHour endHour` |
| `0x01` | `0x0A` | Get latest health sample | `type` (0 HR, 1 SpO2, 2 temp, 3 BP) |
| `0x01` | `0x2F` | Get today's fitness summary | — |
| `0x7F` | — | Multipacket header (responses) | `payload[0..1]` = total packet count LE |

**Pushes (watch → app, no request):**

| Class | Cmd | Name | Payload |
|---|---|---|---|
| `0x06` | `0x80` | **Live health** | `hr, dbp, sbp, rr, stress` (payload[0..4]) — `LiveHealthRes` |
| `0x06` | `0x81` | **Live steps** | steps uint32 LE at payload[0..3]; optional float32 distance + float32 calories (16-B frames) |
| `0x01` | `0x02` resp | HR/BP history day | `(60/interval)×4` bytes per hour: `hr, dbp, sbp, rr` per sample |
| `0x01` | `0x08` resp | **Sleep day** | 6 bytes/hour; each byte = FOUR 2-bit stages × 2.5 min (0 awake, 1 light, 2 deep, 3 REM) |
| `0x01` | `0x26` resp | **SpO2 day** | 1 byte/5-min slot, `0xFF` = no reading |
| `0x00` | `0x06` resp | Device time | yyyy(2) MM dd HH mm ss |
| `0x00` | `0x08` resp | Battery | `batt%` byte |
| `0x00` | `0x02` resp | Firmware version | ASCII string |

## 6. Requirements

| ID | Requirement |
|---|---|
| FR-1 | The watch SHALL appear in the Devices hub scan by name prefix (`stormcall_`) and pair with zero accounts/cloud. |
| FR-2 | Health data SHALL be stored locally only (`WatchStore` → `watchdata.json`, one merged record per day); Apple Health export stays opt-in via the existing owner-profile flow (issue #14 model) — future work. |
| FR-3 | Watch data SHALL NOT mix into scale weight-history attribution (SRD-008); records carry the watch's device id. |
| FR-4 | Protocol knowledge SHALL be ported verbatim from the decompiled Crest app and documented here (this document + `KahaProtocol.swift` source comments). |
| FR-5 | Battery + firmware SHALL surface on the watch's driver page (SRD-006 parity). |
| FR-6 | The watch UI SHALL show live heart rate, live steps, battery, firmware, and per-day HR/sleep/SpO2 history once a day of data is pulled ("Today/Yesterday" picker). |
| FR-7 | Pulled history SHALL persist across launches, merged per calendar day (steps + sleep-stage minutes + SpO2 average + HR-by-hour). |

## 7. Acceptance criteria

1. `stormcall_3_0610` appears in Add-device → Smart Watch scan; tapping pairs it into the hub inventory.
2. The watch page shows live HR updating while worn, today's step count, battery %, and firmware string.
3. HR history request returns per-hour samples rendered as a timeline list.
4. Sleep pull renders stage totals (deep/REM/light/awake) with a per-hour list; SpO2 pull renders the day average + samples.
5. Pulled days survive an app restart (Stored days section lists them from `watchdata.json`).
6. `swift test` ScaleKit (incl. KahaProtocol vector tests) and Yantra xcodebuild stay green.
7. No boAt/Cove cloud endpoints contacted at any point (FR-2/NFR-1).

## 8. Out of scope (this pass)

Watch-face **upload** (the list/switch commands are implemented), BT-call audio control,
manual temperature sessions — the command classes are mapped in the decompiled app and can
be added incrementally behind the same `KahaProtocol` codec.

## 9. Addendum — parity features shipped after the first pass

- **QR pairing (official-app parity):** the Crest app pairs by scanning the QR on the watch
  face. Payload grammar (from decompiled `FragmentQRScanDeviceViewModel.startQRScan`):
  query params `btname=<device name>` plus `mac=`/`mc=<MAC>`; name is percent-decoded,
  uppercased, then the last `_`-suffix segment is dropped to form the scan-filter prefix
  (`stormcall_3_0610` → `STORMCALL_3`); MAC is normalized to colon pairs. Implemented as
  `KahaProtocol.parsePairingQR`, scanned by `WatchQRScannerView` (AVFoundation), connected
  via `WatchCentral.pair(byQR:)` — direct-MAC connect with name-prefix scan fallback.
  Camera usage is declared in Info.plist (`NSCameraUsageDescription`).
- **Control & notification commands:** notifications (0x02 0x75 with
  `[lenLo,lenHi,type,msg…]`), call card + hangup, notification app switches (0x02 0x74),
  music play/pause/volume acks, camera remote (6-byte payload), find-my-watch/
  find-my-phone events (0x02 0x7x family), pairing-confirmation send, watch-face list
  (0x02 0x83) + switch (0x02 0x84), per-day activity summaries (0x01 0x21) for workouts.
- **Health export (issue #29):** `HealthKitWriter.writeWatchDays` writes stored days as
  daily steps, hourly HR samples, sleep-stage category samples (core/deep/REM) and daily
  SpO₂, deduped by `watchDay:<dayKey>` metadata.
- **Sport session control (phone-started workouts):** decompiled
  `CurrentSportModeReq.a()` = `{1, 0x8B, 6, 0, mode, indoorFlag}` with mode ids
  walking=1, running=2, cycling=3, swimming=4, taichi=5, none=0 and
  `indoorFlag = isIndoor ? 0 : 1`; ack `01 8B` payload[0]=1 = success
  (`CurrentSportModesRes`). Pause/resume = `{1, 0x97, 5, 0, 1|2}`
  (`ActivityPauseResumetReq`, ack `01 97` payload[0]=1). Implemented as
  `KahaProtocol.startSportMode/stopSportMode/pauseSportSession/resumeSportSession`,
  surfaced in WatchView as a Start-workout menu with a live elapsed timer, pause/
  resume and end. **Stop semantics:** the official app has no stop command — the
  session is ended on the watch itself (or by re-selecting mode 0); on end, the app
  pulls today's activity summary (`01 23`) so the workout appears in Workouts (#28).
- **QR scanner black-preview fix:** the scanner never requested camera
  authorization, so `AVCaptureDeviceInput(device:)` failed silently while
  `.notDetermined` and the session rendered black. `QRReader.start` now awaits
  `AVCaptureDevice.requestAccess(for: .video)` before configuring; the preview
  layer attaches in `viewDidLoad` and tracks bounds in `viewDidLayoutSubviews`;
  a denied state shows an Open Settings affordance.
