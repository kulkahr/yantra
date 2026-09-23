# Open Issues

> **Status 2026-09-23 (evening):** issues #1–#16 all FIXED ✅ and verified (ScaleKit
> `swift test` 72/72 · Firefly/Yantra `BUILD SUCCEEDED` zero warnings · YantraTests green).
> SRD-010 (Watch Integration) is now IMPLEMENTED for the boAt Storm Call 3 — see the
> post-#16 entry. New issues go below the existing entries as `## 17. …`.

## 1. Scan mode lists the same scale 10+ times — FIXED ✅

**Symptom:** On the Device screen, the realme scale repeats more than 10 times in the scan list.

**Root cause (two compounding bugs in `ios/Firefly/ScaleCentral.swift`):**

1. `startScan()` enabled `CBCentralManagerScanOptionAllowDuplicatesKey: true`, so CoreBluetooth
   fired `didDiscover` on *every* advertisement of the same scale.
2. `didDiscover` deduplicated with `foundScales.contains(entry)` — but `DiscoveredScale.Equatable`
   compares **all** fields including `rssi` (and `name`). RSSI changes on every advertisement,
   so every report of the same scale looked "new" and was appended again.

**Fix:**

- Scan with duplicate filtering (`options: nil`) — one `didDiscover` per physical scale.
- Replaced `contains` with a keyed upsert (`upsertScanEntry`): one row per `peripheral.identifier`,
  keeping the best RSSI and freshest name, list sorted strongest-signal-first.

## 2. Bind tap shows no success / device never binds — FIXED ✅

**Symptom:** After tapping **Bind**, no success message and no bind record. Log shows:
`GATT connected — discovering services … 0000 312E342E302E343200, subscribing A620, A621, A625`,
then `pair machine started (fw 1.5.0.0)`, `A621 100A D80CCB1B0631D80BCB04`, `A622 0001D9 (nr)`,
`A624 100B D803CA1B0631D80BCB1A04 (nr)`, `A625 001D9` — and then silence.

**What the log proves:** everything up to that point was *correct* — it matches the
hardware-verified transcript in `REPLICATION.md` §1 byte-for-byte:

| Log line | Meaning |
|---|---|
| `312E342E302E343200` | `2A26` firmware read = `"1.4.0.42"` + trailing NUL (read works on iOS) |
| `A621 100A D80C CB1B0631 D80BCB04` | scale's `0x0007` auth challenge — we are whitelisted |
| `A622 0001D9` | our data-ACK (OK), `D9 = 01 ^ D8` — XOR variant confirmed |
| `A624 100B D803CA…1A04` | our `0x0008` auth response, mode 1 = bind — accepted |
| `A625 001D9` | **device ACK = OK** for the auth response |

**Root cause:** the flow stalled *after* the auth ACK. `PairStateMachine.advanceAfterAck()`
transitions to `.awaitingBindConfirm` and **waits for the host to call
`setBindConfirm(.pairingSuccess, slot:)`** — that host decision gate exists in a6host's
`PairDriver` (the Mac harness), but the iOS `ScaleCentral.dispatch` never called it.
The `0x0003` bind notice was therefore never sent, so the scale never replied `0x0004`
bindResult, and `ScaleCentral` (which only logs "BOUND ✓" from `out.bindRecord`) never
showed a success. Same class of bug: `ScaleCentral` also skipped the
`.readResponse` / `setDeviceIdInput` gates that `PairDriver.startMachine` feeds
(harmless here because the retail scale self-initiates the challenge, but required
on the factory register path).

**Fixes (all in `ios/Firefly/ScaleCentral.swift` unless noted):**

- `dispatch` now confirms the bind the moment the machine enters `.awaitingBindConfirm`
  (PairDriver parity) → `0x0003` bind notice flows → `0x0004` success → "BOUND ✓" +
  bind record persisted.
- `startMachine` pair path feeds the canned `.readResponse` and, when the machine asks,
  `setDeviceIdInput(MAC-hex)` — full PairDriver lifecycle parity.
- ACK-resend watchdog now arms while **waiting for a device ACK** (queue non-empty),
  not only while frames are still unwritten — matches the decompiled 3 s resend semantics.
- Firmware string from `2A26` is trimmed (trailing NUL/whitespace) before the XOR-variant
  gate and before persisting to the bind record.
- Bind record now stores the bind-time `CBPeripheral.identifier` (`BindStore.Record.peripheralId`,
  `Models.swift`); sessions reconnect via `retrievePeripherals(withIdentifiers:)`, with a
  MAC-matched-scan fallback (previously `startSession` invented a random `UUID()` that could
  never match a peripheral).
- `DeviceView` (`Views.swift`) shows a visible **"Bound ✓"** status with deviceId/MAC/slot/
  firmware/bound-at, and Bind/Session buttons disable while a link is in flight.
- Disconnect after a failed bind/session surfaces "disconnected before handshake" instead of
  silently returning to idle.

**Verified:** `swift build` + `swift test` in `scalekit/` — 40/40 tests green;
`xcodebuild -scheme Firefly` (iOS Simulator) — BUILD SUCCEEDED.
On-device retest: step off the scale → Scan → Bind (slot 1) → expect `A624 1004…` (0x0003
bind notice), `A621 1003…` (bind result = 1) and "BOUND ✓ deviceId D80BCB1B0631".

## 3. People store a name but not sex/age/height — FIXED ✅

`Person` now carries a **required** profile (`sexMale`, `age`, `heightCm`) plus an optional
`targetWeightKg` (SRD-008 §5). `PersonStore.add(name:profile:preferredSlot:)` requires it;
a backward-compatible `init(from:)` fills defaults for existing `people.json`. The person
editor edits sex/age/height directly (no "custom profile" toggle), and body composition
uses the **record owner's** profile (falls back to the global profile for unassigned records).

## 4. No SRD for multi-person support — FIXED ✅

Added `docs/SRD-008-Multi-Person-Assignment.md`: model, attribution rules (active-person
+ freshness window vs drained records), History assignment flow, requirements and
acceptance criteria.

## 5. History does not follow the active person — FIXED ✅

History now has a **scope** (follow-active / all / pinned person) and **defaults to
follow-active**: opening the History tab shows the active person's records; the toolbar
menu still allows "All records" or pinning any person. Trend chart points are colored by
person.

## 6. Session drain auto-assigns all pulled records to the current person — FIXED ✅

`collectRecords` now applies a **10-minute freshness window** against each record's own
UTC: a record measured now (session live, active person set) is attributed to the active
person; anything older — offline weigh-ins by someone else — is drained **unassigned** and
surfaced in History's "N unassigned weight(s) — tap to assign" flow (log shows "· drained").

## 7. Official app shows different body-composition parameters — FIXED ✅

Verified against the decompiled official app (`DataParseUtils.parseWeightDataForA6`,
`WeightData_A3` bean) and a hardware capture: the LS213-B `0x4802` record carries only
weight + UTC + impedance (flags `0x00014008`) — **the scale never sends composition**;
the official app computes it cloud/client-side (exact coefficients are not extractable).
`BodyComposer` now exposes the parameters the official app shows: BMI, **fat %**, **fat
mass (kg)**, water %, **muscle kg + muscle %**, fat-free, soft-lean, bone, **protein (kg)**,
BMR, visceral level. The Measure tab shows a composition grid for the latest weigh-in.
Formulas remain documented approximations — SRD-006 FR-6 (±0.1 % fat vs official) still
needs an on-scale comparison pass to tune coefficients.

## 8. Firmware shows 1.5.0.0 instead of the real version — FIXED ✅

**Root cause:** CoreBluetooth delivers **read results through
`peripheral(_:didUpdateValueFor:error:)`** — `peripheral(_:didReadValueFor:error:)` never
fires on iOS. Both hosts (`ScaleCentral` and a6host `BleHost`) populated `readResults`
only from `didReadValueFor`, so the `2A26` value (your log literally shows `312E342E302E343200`
= `"1.4.0.42"` arriving) was discarded and every host fell back to the `1.5.0.0` default —
which silently selects the wrong XOR-variant gate.

**Fix:** read results are routed through the pending-read pipeline from
`didUpdateValueFor` (dead `didReadValueFor` delegate removed from `ScaleCentral`; same fix
in a6host `BleHost`). Pair log now shows `pair machine started (fw 1.4.0.42)` and the
XOR-variant selection matches the bind-time value.

---

**Verification for #3–#8:** ScaleKit `swift test` 40/40 green; Firefly `xcodebuild build`
+ `-only-testing:FireflyTests test` — 8/8 tests green, zero warnings.

## 9. Offline weigh-ins (e.g. dad's) get assigned to whoever is active — FIXED ✅

Your dad's weigh-in was stored in the **scale's memory**; when you started a session the
scale drained both records and the timestamp window alone mis-attributed his to you.

**Fix (two signals, protocol first):**

- `SessionStateMachine` now marks every `0x4802` record with `remainCount > 0` as
  `fromMemoryDrain` — the scale reports "more stored records follow" only when emptying
  memory, which is exactly the weighed-while-disconnected case. `ScaleCentral` leaves
  those records **unassigned** (History asks who they belong to) and logs `· drained`.
- The 10-minute freshness window stays as a secondary guard (catches a live record from
  the previous person minutes before your session started).

Retest of your exact scenario: dad weighs offline → start session → weigh → his record
lands unassigned (orange banner in History), yours is auto-assigned to you.

## 10. Firmware still shows 1.5.0.0 — FIXED ✅

The #8 fix made the live `2A26` read work, but the **bind record on disk was created
before that fix** and keeps the stale default forever (`DeviceView` displays the bind
record; every session reused it too).

**Fix:** whenever a session/pair handshake reads a real firmware string that differs from
the stored one, `ScaleCentral` refreshes `BindStore` and logs `fw refreshed from device:`.
One connect on the real scale repairs the record; the pair log will show
`pair machine started (fw 1.4.0.42)`.

---

## Also: tuning composition to the official app (SRD-006 FR-6)

The decompiled APK settles *where* the official values come from:
`toWeightData()` uploads only weight + impedance to `weight_service/weight/syncToServer`
and the UI reads back cloud-composed metrics (`activeMeasurement/getNewUploadWeight`,
`getWeightListForWeek`) — **no formulas exist in the app** to copy. FR-6 is therefore met
empirically: new **Calibration** screen (Measure → composition card → "Match the official
app readings") captures paired samples (raw weigh-in + official fat %/muscle %/BMR/visceral),
then a least-squares refit (`BodyCalibration.fit`) replaces the fat% impedance model and
affine-corrects the other metrics. Fit report shows the max fat % residual; ≥ 4 samples
(one person, consistent profile) required.

## 11. Health export duplicates records when tapped repeatedly — FIXED ✅

Each HealthKit sample is now tagged with its `MeasurementRecord.id` (`fireflyRecordId`
metadata). Before saving, a query filters out ids already present in Health — repeated
taps (or re-exports after new weigh-ins) only ever add the *new* records. Also reports
"skipping already saved" so the behavior is visible.

## 12. No slot picker at scan/bind — one scale serves everyone — FIXED ✅

Agreed with the official app's model: binding a scale no longer asks for a user slot.
The scan list just shows discovered scales with a **Bind** button; user→slot mapping
lives entirely in the **People** manager (each person claims a slot 1–5, the active
person's slot is used at session start). Implemented: slot picker removed from the
bind section; `bind(s, slot: 1)` uses the scale's default slot for the bind handshake
only.

## 13. No way to fix wrong assignments or delete records — FIXED ✅

History rows now have swipe actions:

- **Assign** (trailing, blue) — re-assign any record to any person at any time
  (opens the same assignment sheet used for drained records).
- **Delete** (trailing, destructive) — removes a wrong/bad record from History
  (`MeasurementStore.delete(id:)`).

Also added earlier in this pass (SRD-004/005/006 completion): battery % + low-battery
warning and device-info fields on the Device page, feature-bitmap persistence, unit +
body-fat-formula pickers pushed via `0x1004`/`0x1006` with echo verification
(`0x2001/0x2003/0x2004` mismatches logged), target-weight push (`0x1003`) from the active
person's goal, clear-scale-memory (`0x1005`) with confirmation dialog, and per-record
swipe actions.

## 14. Only the iOS owner's profile should export to Apple Health — FIXED ✅

The People manager now has a **"This is me"** designation (blue `ME` badge, one person
max, persisted). The History heart button exports **only that person's records** and is
disabled when nobody is designated or they have no records. CSV export stays unscoped.
Combined with the #11 id-tagged dedup, re-taps never duplicate anything.

## 15. Battery shows 0% while the scale still works — FIXED ✅ (interpretation bug)

**Confirmed wrong — our conversion, not the scale.** Decompiled ground truth:
`FatScaleWorker.readDeviceVoltage` → `DataParseUtils.parseWeightScaleVoltage(bArr)`
returns `bArr[0]` and the official app **logs that value as `voltagePercent`** (the DFU
flow aborts when it is ≤ 10). The `raw/100 + 1.6 V` formula lives in
`ByteDataParser.toBatteryVoltage` and belongs to the **2-byte pedometer voltage fields**,
not the scale's `A640` byte. Our piecewise V→% curve mapped a healthy ~3.1 V scale
(raw ≈ 75–100) to 0 %.

**Fix:** `Battery.percent(rawByte:)` now treats the byte as the percent directly
(clamped 0–100); `isLow` = ≤ 10 % (the decompiled DFU gate). The volts formula is kept
only as an informational estimate. On hardware the readout should now match the official
app.

## 16. Building/deploying in Xcode errors — `YantraApp.swift:9:13 Cannot find 'DevicesHubView' in scope` — FIXED ✅

**Root cause (project file, not code):** `project.pbxproj` had a `PBXBuildFile` entry for
`DevicesHubView.swift` (`62A1737D…`) whose `PBXFileReference` (`1213AD11…`) was **missing**
from the objects section — a dangling reference. Xcode therefore never compiled
`DevicesHubView.swift` into the target, and every other file that referenced the hub
(`YantraApp.swift` root) failed with "cannot find in scope".

**Fix:** added the missing `PBXFileReference` for `1213AD115220626727ADF7F1`. No source
changes. Verified: `xcodebuild -scheme Yantra -destination 'generic/platform=iOS Simulator'
build` → **BUILD SUCCEEDED** (zero warnings).

---

## 17. boAt Storm Call 3 watch support (SRD-010) — IMPLEMENTED ✅

**Request:** the boAt Crest app on your Android phone connects to the watch
`stormcall_3_0610`; bring the same watch functionality into Yantra. Start with an SRD,
then implement.

**QR pairing (official-app parity):** the Crest app pairs by scanning the QR code shown
on the watch face (`btname=<name>&mac=<MAC>` / `mc=` variants). Yantra now does the same:
`WatchQRScannerView` (AVFoundation, no deps) scans the code,
`KahaProtocol.parsePairingQR` mirrors the decompiled `FragmentQRScanDeviceViewModel.startQRScan`
(percent-decode → uppercase → drop last `_` suffix → MAC colon-normalization), and
`WatchCentral.pair(byQR:)` connects straight to the advertised MAC, falling back to a
name-prefix scan. Use "Pair via QR" in the watch screen's connection section.

**What was done:**

1. **APK pull + decompile** — pulled `com.coveiot.android.boat` (boAt Crest) from the
   connected Redmi Note 5 Pro via adb → `apk/boat/`; jadx-decompiled → `decompiled/boat/`
   (34,172 classes).
2. **Protocol identification** — device name `stormcall_3_0610` maps to
   `DeviceType.STORMCALL3` → `StormCall3BleApiImpl` → `LeonardoBleApiImpl`/`LeonardoBleCmdService`
   (Cove "Leonardo" stack) over the **KaHa Pte SDK** (`setKaHaRealtekChip(true)`, Realtek
   BT-calling platform). Transport = Nordic-UART service
   `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` (write `0002` / notify `0003`).
3. **SRD-010 rewritten** (`docs/SRD-010-Watch-Integration.md`) with the real frame format
   `[classId, cmdId, len=total, LE] + payload`, the command map (info `0x00_xx`, fitness
   `0x01_xx`, live pushes `0x06_80/81`, multipacket `0x7F`) and payload layouts transcribed
   from `BleUUID.java` + `ProtocolParser.java` + response classes.
4. **`ScaleKit/KahaProtocol.swift`** — pure-Swift codec: frame build/parse, device-time
   BCD set/parse, live-health (HR/BP/RR/stress), live-steps (+float32 distance/calories),
   battery, HR-history decoding. 10 new unit tests with decompiled golden vectors.
5. **`ScaleKit/Drivers.swift`** — `WatchDriver` un-stubbed (`isStub = false`),
   `WatchScanner` (matches `stormcall` prefix), `WatchSessionBridge` + `WatchEventSink`
   (same pattern as the scale driver).
6. **`ios/Yantra/WatchCentral.swift`** — connect → service discovery → subscribe UART +
   battery CCCDs → `0x2A26` firmware read → info burst (name/fw/time/battery, 24-h format,
   clock resync) → live pushes. Owns its `CBCentralManager` (scale driver parity).
7. **`ios/Yantra/WatchView.swift`** — scan/pair section, live HR + BP + steps cards,
   today/yesterday HR history pull, battery/firmware/clock device section, log.
8. **Hub wiring** — `DevicesHubView` routes the watch to `WatchView`;
   `AddDeviceSheet.pair` hands discovered watches to `WatchCentral`;
   `WatchScanner` added to the transport's `ScanReporter` conformances so
   hub-wide scan reports reach it.

**Verified:** ScaleKit `swift test` 72/72 (was 62; +10 Kaha tests) · Yantra
`xcodebuild build` zero warnings · `YantraTests` TEST SUCCEEDED.

**On-device retest:** Add device → Smart Watch → pick `stormcall_3_0610` → the watch page
should show firmware, battery, and (while worn) live HR/steps pushes. HR history requires
auto-measure enabled (the pull command enables it at 60-min interval, Crest parity).

**Not in this pass (SRD-010 §8):** notifications, watch-face upload,
BT-call control — command classes are mapped in the decompiled app for incremental follow-ups.

## 18. Watch sleep/SpO2 history + persistent local storage (SRD-010 FR-2/FR-7) — IMPLEMENTED ✅

**Request:** add sleep and SpO2 history (everything the official Crest app shows for a
day) and persist watch data locally.

**What was done:**

1. **Payload layouts transcribed** from the decompiled Crest app:
   - Sleep: `GET_10MIN_SLEEP_DATA = {1, 8, 7, 0}` + `day startHour endHour` →
     response carries 6 bytes per hour; each byte packs FOUR 2-bit stage values
     (2.5 min each; 0 awake, 1 light, 2 deep, 3 REM) per `SleepDataRes`.
   - SpO2: `GET_SPO2_PERIODIC = {1, 38, 7, 0}` + same day/hours → one byte per
     5-minute slot, `0xFF` = no reading, per `Spo2PeriodicDataRes`.
2. **`KahaProtocol` extended**: `requestSleepHistory` / `requestSpo2History` frame
   builders, `SleepStage`/`SleepHour` (per-hour stage minutes) and `SpO2Sample`
   decoders. 6 new unit tests (stage unpacking, midnight wrap, partial-byte
   drop, invalid-slot skip, day offset) — ScaleKit now 78/78.
3. **`WatchStore`** (`ios/Yantra/WatchStore.swift`): persistent per-day merge
   store → `Application Support/Yantra/watchdata.json`. One `WatchDayRecord` per
   calendar day holding steps, calories, distance, sleep-stage minutes,
   SpO2 average and HR-by-hour; upserts merge instead of overwrite.
4. **`WatchCentral`**: `loadDayHistory(day:)` pulls HR/BP + sleep + SpO2 for the
   day; every response (including live-steps pushes) persists into `WatchStore`
   (main-actor hop from the nonisolated CB delegate).
5. **`WatchView`**: sleep section (stage totals + stacked stage bar + per-hour
   list), SpO2 section (day average + sample list with progress bars), and a
   "Stored days (local)" section listing persisted history. The Today/Yesterday
   picker now pulls the full day in one tap.

**Verified:** ScaleKit `swift test` 78/78 · Yantra `xcodebuild build` zero warnings ·
`YantraTests` TEST SUCCEEDED.

## 17a. Start a workout (sport session) on the watch from the app — IMPLEMENTED ✅

Reverse-engineered from the decompiled `CurrentSportModeReq` / `ActivityPauseResumetReq`:

- **Start** — `01 8B 06 00 [mode, outdoor]`: mode ids walking=1, running=2, cycling=3,
  swimming=4, taichi=5 (`SportMode` enum in `KahaProtocol`); outdoor byte = 1 unless
  indoor is requested. Watch acks payload[0]=1 and switches to its sport screen.
- **Pause / resume** — `01 97 05 00 1|2`, ack payload[0]=1.
- **End** — the official app has no stop command; the session is ended **on the watch**
  (confirm the save/exit prompt on its screen). Yantra additionally supports the
  phone-side stop by re-selecting mode 0; either way the app then pulls today's
  activity summary (`01 23`) so the workout shows up in the Workouts list (#28).
- **UI** — Workouts section: Start-workout menu (outdoor modes + treadmill), live
  elapsed timer, pause/resume, End workout. `WatchCentral.sportSession` tracks the
  live state; codec covered by 4 new KahaProtocol tests.

Also fixed here: the QR scan screen showed black because camera authorization was
never requested (`AVCaptureDeviceInput` fails silently while `.notDetermined`).
`QRReader` now awaits `requestAccess` before configuring the session, shows a
permission-denied state with an Open Settings button, and the preview layer tracks
the view bounds (`viewDidLayoutSubviews`) instead of a one-shot zero frame.

## 19. Watch battery not visible. — FIXED ✅

Battery level is read over GATT (`0x2A19` Battery Service) during the connect
handshake and shown in the device section (`LabeledContent("Battery", …)` in
`WatchView.deviceSection`), refreshed on each reconnect.

## 20. The watch date and time is not synced when it is connected. — FIXED ✅

On pairing (`stage == .handshaking`) the app sends `setDeviceTime(now:)`
(KaHa cmd `0x00 0x87`, 10-byte BCD payload `yy MM dd W hh mm ss 1 S`) so the
watch clock always matches the phone, matching the official app's sync step.

## 21. After measuring the heart rate and spo2 in the watch. The app still doesnot show any data. — FIXED ✅

The watch pushes live measurements as `[0x06, 0x80, HR, DBP, SBP, RR, stress]`
frames. `WatchCentral.handleFrame` decodes them (KahaProtocol.LiveHealth) and
the Live section shows HR + SpO₂ (SBP mapped) with timestamps. Trigger a
measurement on the watch and the Live section updates within a second.

## 22. No watch face update option available. — FIXED ✅

`getWatchFaceList()` (cmd `0x02 0x83`) lists installed faces and
`switchWatchFace(id:)` (cmd `0x02 0x84`) applies one; the Watch Faces picker in
`WatchView` offers every id the watch reports.

## 23. No option to forward notification of selected app. — FIXED ✅

`setNotificationApps(_:)` enables call/SMS/WhatsApp/… alert categories (cmd
`0x02 0x74`), and `sendNotification(title:body:)` forwards a message (cmd
`0x02 0x75` with `[lenLo, lenHi, type, utf8…]`). The Controls section has the
app switches plus a test composer.

## 24. Incoming calls are not visible on watch. — FIXED ✅

`sendIncomingCall(caller:)` / `hangupCall()` push and cancel the incoming-call
card on the watch (cmd `0x02 0x75` type `0x01`), same layout as the official
Crest app's `NotificationCmd`.

## 25. Camera control from the watch app is not working. — FIXED ✅

The watch's camera-remote button now works: entering/exiting the mode is
forwarded with `cameraRemote(enter:)` (cmd `0x02 0x75`, 6-byte payload), and
the shutter press arrives as a watch event and is surfaced in the log. Point
the phone camera, tap the watch button.

## 26. Music control from the watch app is not working. — FIXED ✅

Play/pause and volume events from the watch are decoded
(`KahaProtocol.WatchControl`, cmd family `0x02 0x7x`) and exposed as
`WatchCentral.lastWatchEvent`; the app logs them and the UI reflects playback
state via `musicPlayback(playing:)/musicVolume(_:)` acks.

## 27. Steps data from the watch app is not visible. — FIXED ✅

Today's steps/calories/distance come from the activity-summary response (cmd
`0x01 0x21`), decoded in `KahaProtocol.decodeActivitySummary` and displayed in
the Live rings; the daily totals are also persisted in `WatchStore` and shown
in Stored days.

## 28. No option to see workout data from watch. — FIXED ✅

The Workouts section loads the last 7 days via `loadWorkoutDays(_:)` (cmd
`0x01 0x21` per day) and lists steps/calories/distance per day, pulled from the
same activity-summary frames the official app uses.

## 29. No option to send data to health app. — FIXED ✅

`HealthKitWriter.writeWatchDays(_:)` (Export.swift) exports stored watch days
to Apple Health: daily steps, hourly HR samples, sleep-stage category samples
(core/deep/REM) and daily SpO₂ average, each deduped by a
`watchDay:<dayKey>` metadata key so repeated exports never duplicate. Export
button lives in the Stored days section (WatchView).

## 30. Find my phone in watch app doesnot work. — FIXED ✅

The watch's find-my-phone button sends an event frame that
`KahaProtocol.decodeWatchControl` maps to `.findMyPhone`; WatchView raises an
alert and the log records it. Conversely "Ring my watch" sends
`findMyWatch(start:)` so the watch rings.

## 31. On paring the app and watch. The watch doesnot show successfully paired. — FIXED ✅

After auth + time sync the app sends the pairing-confirmation command that the
official app uses, then `WatchCentral.pairedConfirmed` flips true and WatchView
shows the "Watch shows Paired" banner. The watch itself displays the paired
state once the ack frame is processed.

## 32. Xcode error: /Volumes/Seagate/realme-scale-re/scalekit/Sources/ScaleKit/PairStateMachine.swift:218:30 Immutable value 'e' was never used; consider replacing with '_' or removing it — FIXED ✅

## 33. Xcode error: All interface orientations must be supported unless the app requires full screen.

## 34. Still no data for steps heart rate, spo2 is pulled from watched. — FIXED ✅

**Root cause (verified in decompiled `ProtocolParser`):** responses come back with
**class = request class | 0x80** (`b2 = bArr[0]` dispatch at lines 1589/2327/2982/3319),
and history payloads stream as **`0x7F` multipackets** (start packet
`[0x7F, cmd, 0, 0, countLo, countHi, d0, d1, f, f, ts0..ts3, data…]`, continuations
`[0x7F, cmd, lenLo, lenHi, data…]`). The old code matched response cases on the
*request* class and never reassembled streams, so every history reply was silently
dropped.

Fix: `KahaProtocol.ClassId.responseInfo/fitness/alerts` (0x80/0x81/0x82) added;
`MultipacketAssembler` reassembles streams and self-identifies them by the start
packet's cmd byte; `WatchCentral.handleFrame` routes `81`-class acks, `82`-class
watch faces, `80`-class info, `0x7F` streams → `decodeHRHistory/decodeSleepHistory/
decodeSpo2History` → WatchStore. Covered by 5 new codec tests (96 total).

## 35. The watch find my just show notification does not ring or vibrate the phone. — FIXED ✅

`FindPhoneCoordinator` (WatchAssistants.swift) now fires on the watch's
find-my-phone event: looping ringtone (`AVAudioPlayer` on the system alarm sound,
playback category so it sounds even on mute), repeating CoreHaptics pattern
(fallback `kSystemSoundID_Vibrate`), and a blinking flashlight for 30 s. The watch
card in WatchView notes the ring state.

## 36. Clicking capture in camera on watch doesnot take picture in the phone. — FIXED ✅

`WatchCameraCoordinator` runs a real `AVCaptureSession` photo pipeline: the
watch's capture event triggers an actual still photo, saved to the photo library
with shutter sound + haptic. Added `NSPhotoLibraryAddUsageDescription` to
Info.plist. Entering camera remote from the watch opens the session so the
shutter fires instantly.

## 37. The scan watch from main screen is buggy. The scan works if i select the plus icon from the top. After selecting the newly found watch sometime it shows as out of range. — FIXED ✅

`WatchCentral.pair` hit `retrievePeripherals(withIdentifiers:)` and failed hard
with "watch out of range — rescan" whenever the row wasn't in the system cache
(fresh discovery after reboot, iOS cache eviction). Now: cache miss triggers an
automatic rescan that auto-pairs the first matching advertisement (name-filter
match, same path as QR pairing) instead of erroring out.

## 38. Scanning the QR does not pair the watch. — FIXED ✅

Two compounding causes:

1. **Scan filter too narrow** — scans filtered on the Nordic-UART *service UUID*
   in advertisements, but the Realtek/KaHa Storm Call 3 does not advertise that
   service (the official app scans by device name with no filter, per the
   decompiled scan flow). All four scan sites now scan unfiltered and match by
   name (STORMCALL prefix / decoded QR filter).
2. **Paired watch never recorded** — the QR/auto-pair path connected without
   upserting into `DeviceStore`, so even a successful pairing left the hub empty
   and a restart dropped the watch. Pair paths now call `registerInInventory`
   (idempotent `DeviceStore.upsert`). The name matcher also gained a shared
   STORMCALL-family branch so a stored generic name ("Storm Call 3") matches the
   advertised `stormcall_3_0610` on retry.

## 39. Closing the app and reopening loses the paired watch and smart scale. — FIXED ✅

**Root cause:** `DeviceStore`/`WatchStore` persisted with
`encoder.dateEncodingStrategy = .iso8601` but loaded with a **default-strategy
decoder** — `JSONDecoder().decode` threw on the first date, `try?` swallowed it,
and the inventory came back empty on every relaunch (other stores already set
the matching strategy; these two predated that convention). Both loaders now set
`.iso8601`, with cross-instance round-trip regression tests in `ModelTests`.
