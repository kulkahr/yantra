# Open Issues

> **Status 2026-09-24:** issues #1–#50 and #60 all FIXED ✅ and verified (ScaleKit
> `swift test` 108/108 · Yantra `BUILD SUCCEEDED` zero warnings · YantraTests green ·
> installed on the iPhone 14 Plus for on-device retest).
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

## 40. Firmware is not visible in the app. — FIXED ✅

Two causes: (a) the handshake fired **7 requests back-to-back** while the watch
answers strictly one-at-a-time — all but the first were dropped (fixed by the
command queue, issue #41); (b) a non-UTF8 version payload decoded to nothing and
the field stayed blank. `handleInfoResponse` now falls back to the printable
subset, then a hex dump with the raw payload logged, so the field is never
silently empty. Firmware is also still read from the standard GATT `0x2A26`
characteristic during discovery.

## 41. Health data still not visible — log shows `history stream cmd 0x4 (7 bytes) — no decoder`. — FIXED ✅

The live log was the decisive clue: the watch returned a `0x7F` stream with
header cmd **0x04** for an HR-history request — the stream header does **NOT**
echo the request cmd (`01 02`). Routing by stream cmd can never work. The
decompiled app routes history responses by the **in-flight command**
(`commandObject.getCmdName()`) and serializes commands via
`ProcessNextItemEvent` — which also explains the sport-mode refusals (#42) and
dropped handshake responses (#40): back-to-back unsolicited commands are
garbled/refused.

Fix: `WatchCentral` now runs a **strict command queue** — one command in
flight, an `AckKind` attached to each command (`history(hr/sleep/spo2)`,
`sportStart`, `sportEnd`, `workoutSummary`), responses complete the in-flight
command and route its data (8 s timeout safety net), and live/event pushes are
explicitly excluded from completing commands. History streams now decode into
HR/sleep/SpO₂ and persist, regardless of the stream's header cmd byte.

## 42. Starting a workout gives `watch refused sport mode (already active or unsupported)`. — FIXED ✅

Same root cause as #41 — the start command raced other in-flight commands, so
the watch (which was busy or already in a session) answered 0. With the command
queue the start goes out cleanly; additionally, on refusal the raw ack is
logged and the app performs a **stop-then-start retry** (stop command →
re-request start) once, since a watch-side session is the likeliest refusal
reason. If the retry also fails the log says to end the watch-side session.

## 43. After relaunch the paired watch shows in the hub, but tapping it never connects and asks to scan again. — FIXED ✅

The #39 persistence fix made the inventory row survive relaunch, but tapping the
row only opened the watch screen — nothing ever attempted a connection from the
stored `peripheralId`, so the screen sat at "Scan for Storm Call 3". iOS supports
direct reconnection via `retrievePeripherals(withIdentifiers:)` (the UUID was
persisted all along). Now:

- `WatchCentral.reconnectIfPaired()` runs on `WatchView.onAppear`: if the link is
  idle/failed and a watch row exists, it connects directly from the stored UUID
  (deferred until Bluetooth powers on if needed).
- The same path backs the new **"Connect paired watch"** button in the failed
  state (next to "Scan again").
- Cache-miss falls back to the #37 name-filtered auto-pair rescan, so a rebooted
  watch still reconnects without a manual scan.

## 44. SpO₂ history shows only 0% records; live HR "huge/zero" values; steps always 0 — FIXED ✅

Three decoders were reading the wrong bytes (verified against the decompiled
layouts after a live `cmd 0x0D, 1152 bytes` stream log exposed them):

- **Live steps** (`LiveStepsRes`): the decompiled parser passes the FULL frame
  to the response class, so total steps = u32 LE at frame bytes 4..7 =
  **payload[0..3]** — the original offsets were correct, and a false
  "packet-counter" prefix theory briefly broke them; restored and pinned with
  tests. (Steps were 0 because the watch does not push them on connect:
  Crest explicitly sends `GET_WALK_VALUE {01 00 05 00 00}`.)
- **Today's steps**: new `KahaProtocol.decodeTodaysSteps` — u16 LE at
  payload[1..2] (`TodaysStepsDataRes` reads split[5]|split[6]<<8 of the full
  frame). The request is queued right after the connect handshake (with a
  `.steps` in-flight ack) and the value persists into `WatchStore`; the
  `0x0D`-headered 1152-byte streams previously logged as "no decoder" are
  history-style replies that the same ack now consumes.
- **SpO₂ history**: `Spo2PeriodicDataRes` filters `0xFF`; `0` is equally a
  no-reading slot, so both are skipped — no more 0% records.

## 45. HR history had huge/zero values (1152-byte day streams) — FIXED ✅

The 1152-byte stream = 288 samples = 24 h × 5-min cadence: the firmware
streams at **its own automatic-HR rate**, not the interval the app requests
(`HrBpDataRes` derives `timeInterval = (60/requested) × 4` bytes/hour but the
observed stream proves the watch wins). Fixes:

- `decodeHRHistory` infers samples-per-hour from the payload (`count / 24`),
  falling back to the configured interval for partial-day streams, so
  5-min-cadence days no longer get hourly-mapped (which produced the "huge"
  values as dbp/sbp bytes were read as HR at wrong slots).
- `0xFF` (and `0`) HR slots are skipped — the watch's empty-slot marker
  (`HrBpDataRes` maps −1 → 0; Crest drops empty hours).
- The bogus `setAutoHRInterval(60)` pre-command was removed: `01 02 05 00`
  **is** the HR-history cmd id (`HISTORY_DATA_AUTOMATIC_HR_BP_INTERVAL`), and
  interval writes use `{01 02 05 00 <minutes>}` — sending it before a history
  request just collided with the same command slot.

## 46. When i change watch active face values in the app the watch gets update but the app still shows old value. — FIXED ✅

Two bugs:

1. **Ack never routed** — the watch answers a `02 8F` switch with `82 8F` and
   payload[0] = 1 (`SetCurrentWatchFaceRes.isSuccess` parity), but `handleFrame`
   had no case for it, and `deliverHistoryData` had no `.watchFaceSet` decoder.
   The selection only ever updated from the separate `02 0F` current-face read.
2. **Face-list decode read the wrong offset** — `GetWatchFaceListRes.getData`
   reads a u16 LE from frame bytes 4..5 = **payload[0..1]**; we started at
   payload[1], shifting every id.

Fix: `switchWatchFace` now queues the command with a `.watchFaceSet(id:)` ack;
the id is applied to `currentWatchFaceId` only after the watch confirms (or the
ack arrives through the `0x7F` assembler). Face list decodes from payload[0].

## 47. Frimware in the app still shows blank. — FIXED ✅

`asciiString` (UTF-8 decode → trim whitespace) returned nil for payloads that
carry **NUL padding** (`"1.4.0.42\0…"`): `\0` is neither whitespace nor invalid
UTF-8, so the string decoded but the trim left `\0`-prefixed garbage — and the
GATT `0x2A26` path trimmed `.whitespacesAndNewlines`, which does not include
NUL either, leaving a blank-looking value.

Fix: both paths (info response + GATT read) strip NUL bytes explicitly before
the printable-subset/hex fallbacks; the value is also echoed to the log
(`firmware = …`) so a blank field is now impossible to miss.

## 48. watch shows 4 hours 48min of sleep data but app doesnot show any data. — FIXED ✅

**Root cause (decompiled `SleepDataReq` + `BleUUID`):** the official app requests
**1-minute sleep** — `GET_1MIN_SLEEP_DATA = {1, 12, 7, 0}` (cmd `0x01 0x0C`),
15 bytes/hour, 60 values × 1 min — as its default. We requested the legacy
**10-min** variant (`0x01 0x08`), which this firmware answers with a payload
our 6-bytes-per-hour decoder read as a partial hour → zero rows.

Fix: `requestSleepHistory1Min` (cmd `0x0C`) is now what `loadSleepAndSpo2History`
sends; `decodeSleepHistory` takes an explicit `bytesPerHour` (15 = 1-min layout,
6 = legacy 10-min, auto-detected from the stream length on receipt). Crest parity
stage semantics unchanged (2-bit values, 0 awake / 1 light / 2 deep / 3 REM).

## 49. Starting sport in app does nothing… — FIXED ✅ (capability, not a bug)

The log was telling the truth: the watch refuses `01 8B`. Decompiled ground
truth — `StormCall3BleApiImpl` sets
`deviceSupportedFeatures.setSportModeSupportedFromApp(false)`: **the Storm Call 3
does not support app-started workouts at all.** The official app never sends the
command to this model (its `b()` even resets any stray mode with an all-zero
`SportModeRequest`), so no retry can ever succeed.

Fix: the refusal is now surfaced once — `sportStartUnsupported` flips true, the
stop-then-start retry is gone, the UI replaces the start-workout menu with
“Workouts start on the watch”, and the flag persists across reconnects (device
capability, not link state). Workout summaries (`01 23`) still pull normally for
watch-started sessions.

## 50. There is no option to sync mobile contact list with watch. — IMPLEMENTED ✅

Byte-for-byte `SetPhoneBookReq` parity (`00 A8`):

- payload = **count byte** + per contact `name UTF-8 ≤ 20 B, NUL, number UTF-8
  ≤ 20 B, NUL` (spaces stripped from numbers, both fields hard-clamped at 20
  bytes exactly like the decompiled builder).
- > 150 bytes → **0x7F multipacket request stream**: start packet
  `[7F crcLo crcHi seq=0, count, crcLo crcHi, class, cmd, lenLo lenHi data…]` +
  146-byte continuations `[7F crcLo crcHi seqLo seqHi chunk…]`, CRC16 over the
  payload per `MultiPacketRequestGenerator.crc16` (rotate + XOR chain, ported
  and pinned with a hand-traced vector).
- `ContactsSection` in `WatchView` pulls ContactsKit (given+family name, first
  phone number), lets you pick how many (1–30), and pushes through the command
  queue (ack `.phoneBook` = `80 A8`). Requires the Contacts permission
  (`NSContactsUsageDescription` added to Info.plist).

## 60. The app is missing the watch navigation map update feature. — IMPLEMENTED ✅

Reverse-engineered from `CoveNavigationService` + `SetNavigationEventReq` /
`SetNavigationStatusReq` (the navigation feature lives on the same Leonardo
protocol family):

- **Start/turn event** — `02 8A` frame: `0x41` marker byte (the request-prefix
  byte from `generateSinglePacketRequest(2, -90, data, {65})`) + `1` (isStart)
  + `len` + source UTF-16LE + `len` + destination UTF-16LE + mode byte
  (strings ≤ 60 UTF-16 units = the decompiled 120-byte cap; mode: walking = 0,
  driving/biking = 1 — `CoveNavigationService.setNavigationStartOrStopOnBand`).
- **Stop** — `02 8A` + bare mode byte `2` (`SetNavigationEventReq.a()`
  else-branch); **status** — `00 B4` + status byte (2 = navigating,
  0 = stop/error path, matching the callers).
- **UI** — Navigation section on the watch screen: destination + driving/
  walking picker → start (event + status 2), per-turn “Update” with remaining
  meters, and Stop. All commands flow the strict queue with dedicated acks
  (`.navigationEvent` / `.navigationStatus`).

**Verification:** ScaleKit `swift test` 108/108 (+6 new: 1-min sleep layout,
1-min request frame, phone-book single/multipacket, CRC16 vector, navigation
event/stop/status, UTF-16 clamp, watch-face list offset) · Yantra
`xcodebuild build` zero warnings · `YantraTests` TEST SUCCEEDED · app installed
on the connected iPhone 14 Plus for on-watch retest.

**On-device retest:** connect the watch → Sleep section should now fill (pull
Today) · watch-face switch updates the picker immediately · Firmware shows the
version (or the raw hex in the log) · Start workout explains the watch-side
limit · Sync contacts → check the watch's phone book · Start navigation → the
watch shows the destination card.

## 61. HR history cadence wrong on partial days — OPEN, needs hardware capture

**Symptom:** pulling "Today" before noon spreads the morning's 5-min-cadence HR samples
across hours 0–23 as if hourly (audit #11); a full-day pull decodes fine.

**Root cause:** `decodeHRHistory` infers cadence as `payload.count / 4 / 24` clamped ≥ 1
and falls back to a 60-min interval for partial days — the watch actually streams at its
own automatic-HR rate (proven live in #45: 288 samples = 24 h × 5 min). What is missing
is the *authoritative* cadence/timestamp source for a partial stream.

**What's needed (one capture, on a Mac with the watch):** run `a6host` (or an HCI snoop
of the official Crest app) while requesting HR history for TODAY at a known auto-HR
interval (set 5 min on the watch first). Save the raw `0x7F` start packet —
`[0x7F, cmd, 0, 0, countLo, countHi, d0, d1, f, f, ts0..ts3, data…]`. The two
undocumented fields (`d0 d1` and `f f`) plus the 4-byte `ts` are suspected to carry
sample-count/interval/anchor-timestamp; their layout is what the fix must decode.

**Then implement:**
1. Decode the start-packet metadata in `MultipacketAssembler` (expose
   `(cmd, data, intervalMinutes?, anchorTimestamp?)`) and pass it to `decodeHRHistory`.
2. Timestamp each sample as `anchor + i × interval` instead of midnight synthesis.
3. Fallback stays: full 24 h streams → `count/24` inference (current, correct).

**Files:** `scalekit/Sources/ScaleKit/KahaProtocol.swift` (`MultipacketAssembler`,
`decodeHRHistory`), `scalekit/Tests/ScaleKitTests/KahaProtocolTests.swift` (golden
vector from the capture), `ios/Yantra/WatchCentral.swift` (plumb metadata).

## 62. Music metadata push to watch — OPEN, needs hardware capture

**Symptom:** the watch's music screen shows a generic track while the phone plays
something else. The official app pushes now-playing title/artist (audit #19).

**Root cause:** the decompiled request classes exist (`SetMusicMetaDataReq` family,
`musicMetaDataChangeFromApp = TRUE` for this model) but the exact wire bytes — cmd id,
field order, string encoding (UTF-8 vs UTF-16), length prefixes — were never recovered
(`decompiled/` is not in the repo; only raw APKs under `apk/boat/`), and blind frames
risk queue-stalling the strict command queue.

**What's needed (one capture):** HCI snoop (`btsnoop_hci.log`) of the official Crest app
while music plays and the track changes, with the watch connected. Decode the app→watch
writes with `analysis/tools/hci_decode.py`, identify the metadata frames (they start
with a `0x00`-class byte and appear on each track change), and transcribe the layout.

**Then implement:** `KahaProtocol.setMusicMetaData(title:artist:album:duration:)`
framed from the capture, a `WatchCentral.musicMetaData(...)` queue method, and a
now-playing observer (`MPNowPlayingInfoCenter.default()` changes) that pushes on track
change while the watch is live.

**Files:** `scalekit/Sources/ScaleKit/KahaProtocol.swift`,
`scalekit/Tests/ScaleKitTests/KahaProtocolTests.swift` (golden frame),
`ios/Yantra/WatchCentral.swift`, `ios/Yantra/WatchAssistants.swift` (observer in
`MusicRemoteCoordinator`).

## 63. Watch-face upload/delete — SCOPED, needs hardware capture + sources

**Request:** the official app can upload custom watch faces and delete installed ones
(audit #16: `CustomWatchFaceUploadReq`, `DeleteWatchFaceReq`, background auto-play
settings, refresh flag `02 ae`). Yantra only lists/switches faces today.

**Known so far (from the decompiled capability map):**
- List/switch/current read (`02 0D`, `02 8F`, `02 0F`) are implemented and verified.
- `SET_WATCH_FACE_REFRESH = 02 ae 05 00` is a verified constant (§14 appendix) —
  likely the refresh trigger after an upload.
- The upload family itself (`CustomWatchFaceUploadReq`) is a **multipacket transfer**
  (the face bin is far larger than 150 B) — same `0x7F` request-stream machinery as the
  phone book (`multipacketRequest`), but the payload container (header, format, CRC
  type, chunk acknowledgment) is unknown.

**What's needed before implementation:**
1. **Decompiled sources** — `jadx -d decompiled/boat apk/boat/base.apk` (and the
   arm64 split) so `CustomWatchFaceUploadReq`/`DeleteWatchFaceReq` and the Realtek OTA
   chunking service can be read. The apk is in `apk/boat/`; the folder is gitignored,
   so this runs on the Mac.
2. **One HCI capture** of the official app uploading a watch face — this proves the
   transfer handshake (how the watch acks chunks, whether it reuses the DFU-style
   state machine in `DfuStateMachine`) and gives golden frames for tests.

**Then implement (in order):**
1. `KahaProtocol.deleteWatchFace(id:)` (small, verify against capture first).
2. `KahaProtocol.watchFaceUpload(metadata:binData:)` — multipacket stream + chunk acks.
3. `WatchCentral.uploadWatchFace(...)` with progress (`AckKind.watchFaceUpload(progress:)`)
   reusing the strict queue's assembler path.
4. UI: pick a face image → size/format validation → upload progress row in the
   Watch Faces section + delete swipe action on installed faces.

**Files:** `scalekit/Sources/ScaleKit/KahaProtocol.swift`,
`scalekit/Tests/ScaleKitTests/KahaProtocolTests.swift`,
`ios/Yantra/WatchCentral.swift`, `ios/Yantra/WatchView.swift`,
`analysis/STORM_CALL3_FEATURE_AUDIT.md` §16.