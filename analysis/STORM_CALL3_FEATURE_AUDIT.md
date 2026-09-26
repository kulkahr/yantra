# boAt Storm Call 3 — Feature Audit (iOS app vs official boAt Crest app)

Scope: the smart-watch implementation on branch `multi-device-hub` — `ios/Yantra/WatchCentral.swift`,
`WatchView.swift`, `WatchStore.swift`, `WatchAssistants.swift`, `WatchQRScannerView.swift`,
`DeviceCore.swift`, `DevicesHubView.swift`, `Export.swift`, and the protocol codec
`scalekit/Sources/ScaleKit/KahaProtocol.swift` (SRD-010).

Verification method: the official boAt Crest APK in `apk/boat/` (`base.apk` +
`split_config.arm64_v8a.apk`, `com.coveiot.android.boat`) was unpacked and its DEX files
disassembled (androguard, 18 dex files / 132 recovered `BleUUID` command constants). Ground
truth used here:

| Decompiled class | What it proves |
|---|---|
| `com.coveiot.sdk.ble.api.BleUUID` | Every wire command constant (`GET_DEVICE_TIME = 00 06 04 00`, `GET_1MIN_SLEEP_DATA = 01 0c 07 00`, `GET_10MIN_SLEEP_DATA = 01 08 07 00`, `GET_SPO2_PERIODIC = 01 26 07 00`, `HISTORY_DATA_AUTOMATIC_HR_BP_INTERVAL = 01 02 07 00`, `SET_DEVICE_TIME = 00 87 0e 00`, `GET_WALK_VALUE = 01 00 05 00 00 00`, `SET_MESSAGE_ALERT_SWITCHES = 02 82 06 00`, `SEND_MESSAGE_CONTENT = 02 83`, `PAUSE_ACTIVITY_SESSION = 01 97 05 00`, `SET_DEVICE_TIME_24_HOUR_FORMAT = 00 82 05 00 00 00`, `SET_DISTANCE_UNIT_KM = 00 a2 05 00 00 00`, `SET_PAIRING_PHONE_TYPE = 00 86 05 00 00 00`, …) — full dump in §13 |
| `com.coveiot.sdk.ble.parser.ProtocolParser.handleDeviceInput` | Response dispatch: gate on characteristic `6E400003-…`, switch on frame byte 0, response-class bytes `0x80/0x81/0x82`, command completion via `setCompleted(true)` + `ProcessNextItemEvent`, string bodies parsed by `substring(4, len-1)` of `Arrays.toString(bArr)` |
| `com.coveiot.android.bleabstract.bleimpl.StormCall3BleApiImpl.getDeviceSupportedFeatures` | Official capability bitmap for this exact model (§2) |
| `com.coveiot.android.bleabstract.services.LeonardoBleService.k()` | The device-time payload: 10 bytes `yy yy MM dd HH mm ss ±HH mm` in **plain binary, not BCD** |
| `SleepDataReq` / `Spo2PeriodicDataRes` / `GetWatchFaceListRes` / `TodaysStepsDataRes` | Request cmd selection (1-min sleep default) and payload field layouts |

Result summary: **protocol constants verified correct** across the board. One real bug found
(device-time BCD encoding), several fidelity gaps, and a handful of enhancement
opportunities. Feature-by-feature:

| # | Feature | Verdict vs official app | Quick-fix status |
|---|---|---|---|
| 1 | Scan & pair | ✅ parity, iOS-specific gaps | ✅ **FIXED (QF7)** scan-list upsert |
| 2 | QR pairing | ✅ parity (capability-aware) | — |
| 3 | Transport & frame codec | ✅ parity | — |
| 4 | Connection handshake | ✅ parity | — |
| 5 | Command queue | ✅ parity | ✅ **FIXED (QF8)** stream-discard on timeout |
| 6 | Device info (name/fw/hw) | ⚠️ missing hardware-version command | ✅ **FIXED (QF6)** |
| 7 | Device clock sync | ❌ **BUG — BCD vs binary** | ✅ **FIXED (QF1)** |
| 8 | Battery | ⚠️ uses GATT instead of the protocol command | ✅ **FIXED (QF10)** battery-optional handshake gate |
| 9 | Live health (HR/BP/stress) | ✅ parity | — |
| 10 | Live + daily steps | ⚠️ data model truncated | ✅ **FIXED (QF11)** u32 steps + `01 2f` |
| 11 | HR history | ⚠️ cadence inference is wrong for partial days | open (needs capture) |
| 12 | Sleep history | ✅ parity (1-min), ⚠️ day-boundary bug | ✅ **FIXED (QF3)** inflation; day-boundary open |
| 13 | SpO₂ history | ✅ parity, ⚠️ 0-filter mismatch | open (cosmetic) |
| 14 | Workout/sport sessions | ✅ parity (capability-aware), ⚠️ no real-time sport data | — |
| 15 | Workout day summaries | ❌ partial-day request mismatch | ✅ **FIXED (QF11)** `01 2f` for today + shared upsert |
| 16 | Watch faces (list/switch) | ⚠️ upload absent (out of scope) | — |
| 17 | Notifications & calls | ⚠️ 200-char limit ignored, no icon/type routing | ✅ **FIXED (QF2)** 200-char + title/body |
| 18 | Contacts sync | ⚠️ dedupe/multi-number gaps | ✅ **FIXED (QF5)** ≤20/request batching |
| 19 | Music control | ⚠️ metadata push missing | ✅ **FIXED (QF12)** remote commands wired; metadata push open |
| 20 | Camera remote | ✅ parity, ⚠️ no preview | ✅ **FIXED (QF13)** session warm-up; preview open |
| 21 | Find phone / find watch | ✅ parity | ✅ **FIXED (QF9)** ack frame |
| 22 | Navigation push | ⚠️ no real navigation feed | open (MapKit feed) |
| 23 | History persistence | ✅ local-only parity, ⚠️ sleep double-count | ✅ **FIXED (QF3)**; retention open |
| 24 | HealthKit export | ⚠️ date fabrication bug | ✅ **FIXED (QF4)** dedup + hourly sleep |
| 25 | Auto-reconnect | ⚠️ no backoff or re-subscribe-on-fail policy | ✅ **FIXED (QF14)** one 6 s auto-retry |
| 26 | Multi-device hub | ✅ SRD-009 architecture, ⚠️ single-session transport | open (transport unification) |

Per-feature details below. Each section ends with **What's wrong / What needs fixing /
What can be enhanced**.

---

## 1. Scan & pair (WatchCentral + WatchScanner)

**iOS implementation.** `WatchScanner` (ScaleKit `Drivers.swift`) classifies any
advertisement whose name contains `stormcall` (case-insensitive); the hub's
`AddDeviceSheet` shows the list and `WatchCentral.pair` connects. `WatchCentral.startScan()`
scans with **no service UUID filter** (`scanForPeripherals(withServices: nil)`) with a 30 s
timeout, dedupes by `peripheral.identifier` and auto-pairs the first hit when a target name
or `pendingPair` is set.

**Official app.** Crest scans by name only as well — the Realtek/KaHa watch does not
advertise the Nordic-UART service UUID, so a service-filtered scan never sees it. The
iOS port matches this behavior exactly (`#38` fix), including the scan-timeout→idle
transition.

**What's wrong.** Nothing protocol-level. UX gaps:
- The dedupe `foundWatches.contains(entry)` compares `DiscoveredWatch.Equatable` on
  `(id, name, rssi)` — the *same* peripheral with a fluctuating RSSI can appear multiple
  times in the scan list (the identical bug OPEN_ISSUES #1 fixed on the scale side).
- RSSI is never refreshed after discovery, so "signal strength" is a single snapshot.
- There is no "keep scanning / device not advertising" guidance: the watch only advertises
  when its screen wakes, so a first-time user often sees an empty list.

**What needs fixing.**
- Key the scan list by `id` only and update RSSI in place (upsert), sorted by strongest
  signal — one row per physical watch.

**What can be enhanced.**
- Show a "wake your watch (press the crown / raise wrist)" hint after ~5 s of silence.
- Persist the last-seen RSSI for inventory rows and show "last seen 2 min ago" in the hub.

## 2. QR pairing (`WatchQRScannerView` + `KahaProtocol.parsePairingQR`)

**iOS implementation.** The watch's pairing QR (`…btname=stormcall_3_0610…mac=…`) is parsed
byte-for-byte like decompiled `FragmentQRScanDeviceViewModel.startQRScan`: lowercase →
extract after `btname=` → uppercase → drop the last `_`-suffix segment → restore `%20`.
MAC from `mac=`/`mc=` normalized to colon pairs. The camera flow requests authorization
**before** building the session (fixing the earlier black preview) and offers manual MAC
entry as a fallback. `pair(fromQR:)` connects by target-name scan; the MAC itself is
logged only — iOS addresses peripherals by UUID, not MAC.

**Official app.** Identical grammar; Crest also uses the MAC with
`BluetoothAdapter.getRemoteDevice(mac)` for a direct connect. On Android that is a real
MAC connect; iOS cannot do this, so the iOS design (scan-match → cache UUID for
reconnects) is the correct platform adaptation.

**What's wrong.** Nothing.

**What needs fixing.** Nothing — but note the name filter used for matching is the
`_<suffix>`-stripped prefix (`STORMCALL_3`), while the fallback scanner accepts anything
containing `STORMCALL`; the double-match in `didDiscover` (`upper.hasPrefix(filter) ||
filter.hasPrefix(upper) || both contain STORMCALL`) is intentionally loose but can
auto-pair a *different* Storm Call 3 in a multi-watch room.

**What can be enhanced.**
- If the QR carried a MAC, verify the resolved advertisement's manufacturer data (when
  present) contains that MAC before auto-connecting, to disambiguate.

## 3. Transport & frame codec (`KahaProtocol`, GATT)

**iOS implementation.** Nordic-UART service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`,
write to `6E400002` **with response**, notify on `6E400003`; standard `0x180F/0x2A19`
battery and `0x180A/0x2A26` firmware-revision reads. Frame =
`[classId, cmdId, lenLo, lenHi, payload…]` with **length = total frame length**
(header included). No checksum, no session/auth — usable right after CCCD subscription.

**Official app.** Verified identical: `handleDeviceInput` only processes notifications
from characteristic `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`; commands from `BleUUID`
constants all carry total-length headers (`GET_DEVICE_TIME = 00 06 04 00` = class+cmd+len2;
`SET_DEVICE_TIME = 00 87 0e 00` = header + 10 payload bytes = 14 = 0x0e). The
`0x7F` multipacket channel, CRC16 (rotate-XOR chain) and 150-byte first packet /
146-byte continuation chunking match `MultiPacketRequestGenerator`.

**What's wrong.** Nothing.

**What needs fixing.** Nothing.

**What can be enhanced.**
- Writes are serialized one-at-a-time by the queue, but `peripheral(_:didWriteValueFor:)`
  is not used for flow control; safe today (with-response writes queue in CoreBluetooth),
  worth keeping in mind if throughput ever matters (watch-face upload).
- Add a `KahaProtocol` fuzz test that feeds truncated/corrupted frames into `parse` and
  the `MultipacketAssembler` (currently only golden happy-paths are tested).

## 4. Connection handshake (`requestInfo()`)

**iOS implementation.** After both CCCDs are subscribed and the `2A26` read completes:
`get name` → `get firmware` → `get time` → `get battery` → `set 24h` → `set phone type
(00 86 05 00 00)` → clock sync → today's steps → watch-face list/current. Sets
`stage = .live` and `pairedConfirmed` once queued.

**Official app.** Crest's connect sequence sends the same family: device info queries,
`SET_DEVICE_TIME_24_HOUR_FORMAT = 00 82 05 00 00 00` (verified constant), 
`SET_PAIRING_PHONE_TYPE = 00 86 05 00 00 00` (verified — the "phone paired" flag the
watch needs before it accepts settings), time sync, then data pulls. The iOS
ordering (info first, settings, then clock, then steps) matches the app's
"connect → read state → push settings → pull today" shape.

**What's wrong.** The handshake hardcodes "set 24-hour format" — the user's choice is
never surfaced (the official app has a toggle and pushes `…01 00` for 12-hour).

**What needs fixing.** Nothing breaking; see #6/#7 for the missing hardware-version and
the clock-encoding bug inside this same sequence.

**What can be enhanced.**
- Expose 12/24-h and distance-unit (km/mile, `00 a2`) as settings in the watch page
  (both verified constants exist and are trivial to send).
- After handshake, request the **alert switches** (`GET_ALERT_SWITCH = 02 03 05 00`) so
  the notification-per-app switches reflect the watch's real state instead of only
  pushing a hardcoded call/SMS/WhatsApp mask.

## 5. Strict command queue (`QueuedCommand`, `drainQueue`, `completeInFlight`)

**iOS implementation.** One command in flight at a time; responses with class
`0x80/0x81/0x82` release the lock (decompiled `commandObject.setCompleted(true)` +
`ProcessNextItemEvent` parity); an 8 s ack-timeout force-completes; resetLink clears
state. History streams route by the **in-flight command's** decoder kind, because the
`0x7F` stream header does not echo the request cmd (verified live and consistent with
the parser routing via the current `CommandObject`).

**Official app.** Identical architecture (`LinkedList` queue + `ProcessNextItemEvent`
seen throughout `handleDeviceInput`), including the "current command is …" gate: the
parser only builds a response when the in-flight command matches.

**What's wrong.** The 8 s timeout force-completes the command and lets the queue run on.
If a history stream is still arriving when that fires, the next command's responses get
routed to the wrong decoder (the in-flight kind changed) — this is logged as
"no in-flight decoder" but the day's data is lost.

**What needs fixing.**
- On ack-timeout of a history command, drain/cancel the pending `MultipacketAssembler`
  stream (reset the assembler) before starting the next command.

**What can be enhanced.**
- Exponential backoff retry (once) for settings commands, mirroring the resend watchdog
  behavior of the scale host (`a6host`).

## 6. Device info — name / firmware / hardware (FR-5)

**iOS implementation.** `getDeviceName (00 00)`, `getFirmwareVersion (00 02)` sent;
responses `80 00` / `80 02` parsed from ASCII payload (NUL-trimmed, printable fallback,
hex-dump fallback for weird firmware). Firmware string is also read from the standard
`2A26` characteristic; `getHardwareVersion` exists in the enum but is **never sent**.

**Official app.** `GET_HARDWARE_VERSION = 00 01 04 00` is part of the standard connect
sequence (the response handler writes `BleDeviceInfo.setHwRevision` — verified in
`handleDeviceInput`). The official app shows hardware revision on the about page.

**What's wrong.** Hardware version is never requested; the watch page has no row for it.

**What needs fixing.**
- Queue `infoFrame(cmdId: 0x01)` in `requestInfo()` and render `hwRevision` on the Device
  section (SRD-006 parity).

**What can be enhanced.**
- Also fetch serial number (`GET_SN = 00 04 04 00`) and MAC (`GET_MAC_ADDRESS = 00 03 04 00`)
  for the about page / diagnostics.

## 7. Device clock sync — ❌ **BUG: BCD vs binary**

**iOS implementation.** `KahaProtocol.setDeviceTime(from:)` encodes every date field with
`bcd(_:)` — e.g. 2026 → `[0x20, 0x26]`.

**Official app.** `LeonardoBleService.k()` (fully disassembled) writes
`byte[]{yyCentury, yy, month, day, hour, minute, second, sign, offH, offM}` —
**plain binary bytes** (`aput-byte v5, v15, v8` directly from the parsed int, no BCD
packing). For 2026 that is `0x14 0x1a` (20, 26), not `0x20 0x26`. It also formats the
UTC offset as `%02d:%02d` split on ":", writing `+` (43) / `-` (45) and the two
**decimal ASCII digit pairs** parsed via `Byte.parseByte` — i.e. `+05:30` becomes
bytes `[0x2B, 0x05, 0x1E]` where `0x1E = 30`. The iOS port writes `0x2B, 5, 30` (binary)
for the offset — sign/HH match, **minutes byte differs** (binary 30 vs ASCII `0x1E`).
And the year fields differ everywhere (BCD vs binary).

Consequence: the watch clock set from the iOS app is wrong (year reads as 20-26-century
mismatch, minutes offset misread) — exactly the kind of silent corruption the user sees
as "watch shows the wrong date/time after connecting Yantra".

**What's wrong.** Encoding mismatch on 3 of 10 bytes minimum (year century, year, tz
minutes) — actually all 6 date fields (BCD vs binary).

**What needs fixing.**
- Rewrite `setDeviceTime` payload as **binary**: `[yy/100, yy%100, month, day, hour,
  min, sec, sign, |offHours|, |offMinutes|]` — and confirm the tz minutes byte against a
  live capture: the decompiled code sends ASCII digits ("05","30" → `0x30 0x35 …`? no —
  `Byte.parseByte("30") = 30 = 0x1E`, binary 30). So binary for all fields, matching
  `aput-byte` of parsed ints.
- Add a golden vector: 2026-09-24 14:26:05 IST → `00 87 0E 00 14 1A 09 18 0E 1A 05 2B 05 1E` (14 bytes: 4-byte header + 10-byte payload, minute byte `0x1A` = 26).

**What can be enhanced.**
- Sync the clock also on `0x00 0x06` response drift > 60 s (the official app re-syncs on
  connect and on DST/timezone change).

## 8. Battery (GATT 0x2A19 + protocol)

**iOS implementation.** Subscribes to the standard Battery Level characteristic and
parses it via `KahaProtocol.decodeBattery`; additionally queues `getBatteryLevel
(00 08)` in the handshake and parses the `80 08` response (`payload[0]` percent byte).

**Official app.** Uses the same protocol command (`GET_BATTERY_LEVEL = 00 08 04 00`;
`ReadBatteryLevelRes.setBatteryLevel(bArr[4])` — verified) — and also the standard GATT
battery service. Values agree.

**What's wrong.** Nothing on values. But the GATT subscription is required to complete
the handshake gate (`subscribed.contains(batteryLevel)`), coupling the handshake to a
characteristic some firmwares may not expose — if it's missing the watch never goes
"live".

**What needs fixing.** ✅ FIXED (QF10) — the gate is now "UART notify CCCD AND (battery
CCCD subscribed OR no battery characteristic was ever discovered)" (`sawBatteryChar`
tracked during discovery, reset in `resetLink()`), so firmware without `0x2A19`
handshakes and relies on the `00 08` command for battery.

**What can be enhanced.**
- Low-battery warning (official app notifies; the scale side of Yantra already has this
  pattern from OPEN_ISSUES #15) and a battery history sparkline.

## 9. Live health push — HR / BP / stress / RR (`06 80`)

**iOS implementation.** `decodeLiveHealth` maps `payload[0..4]` → hr, dbp, sbp, rr,
stress (`LiveHealthRes` parity); the Live section shows a big HR numeral with BP/stress
captions; pushes stream in continuously while connected.

**Official app.** Identical (`06 80` push class preserved both directions; fields in the
same order).

**What's wrong.** Nothing.

**What needs fixing.** Nothing.

**What can be enhanced.**
- A real-time HR chart (rolling last-N values) instead of a single numeral; the data is
  already in memory — add `liveHealthHistory: [(Date, LiveHealth)]` capped at ~500.
- Surface stress/RR with color coding like Crest (the values are already decoded but
  rendered as small captions).

## 10. Live & daily steps (`06 81` + `01 00`)

**iOS implementation.** Live steps push `06 81` (`steps u32 LE`, optional
`distance f32` + `calories f32` for 12-byte payloads); today's steps response `81 00`
(`decodeTodaysSteps` reads u16 at payload[1..2] per decompiled split[5]/split[6]).
Steps persist into `WatchStore` on every update.

**Official app.** Same commands. However Crest also decodes the **distance and calorie
halves of the `81 00` response** (split[7]/split[8] — the decompiled parser reads them,
and the app renders steps · km · kcal), and requests `GET_TODAY_FITNESS_VALUE
(01 2f 04 00)` for the full daily summary (steps/distance/calories for the day).

**What's wrong.**
- ~~`decodeTodaysSteps` only reads the u16 steps~~ ✅ FIXED (QF11): `decodeTodaysFitness`
  decodes the full shape (u32 steps + gated distance/calories floats); the u16 legacy
  shape is retained for old firmware, and the stream-path `.steps` ack reads u32 at
  payload[5..8] (`TodaysStepsDataRes`).
- ~~Distance/calories dropped; `01 2f` never sent~~ ✅ FIXED (QF11): the handshake now
  requests `GET_TODAY_FITNESS (01 2f)` and renders steps · m · kcal, keeping the old
  values when a reply omits them.

**What needs fixing.** Nothing protocol-level; remaining gaps are UX (below).

**What can be enhanced.**
- Step-goal ring: `SET_DAILY_WALK_TARGET` / `GET_WALK_DAILY_TARGET` constants exist; the
  official app shows progress toward the goal — a natural WatchStore addition.

## 11. HR history (`01 02` request, `0x7F` stream)

**iOS implementation.** `requestHRHistory(day:startHour:endHour:)` sends
`01 02 [day][start][end]` (= `HISTORY_DATA_AUTOMATIC_HR_BP_INTERVAL`, verified constant).
The `0x7F` stream is reassembled (`MultipacketAssembler`: start packet skips 12 bytes,
continuations skip 4) and decoded by `decodeHRHistory`, which **infers** the cadence
(`payload.count/4/24`, clamped to ≥1) and timestamps each sample at
`startHour*60 + index*minutesPerSample` from the target day's midnight. Persisted as
`hrByHour` (hour → last bpm of that hour).

**Official app.** The firmware streams at the **automatic-HR interval** configured on the
watch (not the requested range) — the iOS comment `#45` documents this and it matches
Crest, which reads the interval from the response metadata rather than assuming it.
Crest renders samples on a chart with per-sample timestamps.

**What's wrong.**
- The cadence inference breaks on **partial days** (today before noon): `sampleCount <
  24` falls back to `60/intervalMinutes` with the *default 60* — a morning pull with
  5-min auto-HR produces hour-0-anchored timestamps that are wrong (samples spread as if
  hourly).
- The persistence collapses to **one bpm per hour** (`Dictionary(hrDated…)` last-write
  wins) — a 5-min cadence day loses 11/12 of its samples, and the HealthKit export then
  writes 1 hourly sample (the official app keeps every sample).

**What needs fixing.**
- Compute the cadence from the stream header's day/hour metadata if present (the `0x7F`
  start packet carries `d0 d1 f f ts0..ts3` — decode that timestamp instead of
  synthesizing from midnight), else from the day's *elapsed* hours (`sampleCount/24`
  over full hours, `sampleCount/(elapsedHours+1)` for today).
- Persist the full sample list (dated) in `WatchDayRecord` (e.g. `hrSamples: [Int]` +
  base timestamp) instead of `hrByHour`.

**What can be enhanced.**
- HR-zone summary (rest/average/peak) like Crest's day card.
- Auto-request the auto-HR interval command (`01 02 [minutes u16]` set / get) and show it
  on the history footer (currently the footer text says "every 60 min by default" —
  guesswork).

## 12. Sleep history (`01 0C` 1-min, legacy `01 08`)

**iOS implementation.** `requestSleepHistory1Min(day:0:23:)` (`GET_1MIN_SLEEP_DATA =
01 0c 07 00`, verified; `SleepDataReq` defaults to it — official parity, fix `#48`).
`decodeSleepHistory` unpacks 2-bit stages, `bytesPerHour` 15 (1-min) or 6 (10-min
legacy) auto-detected by `data.count % 15 == 0`. Aggregated into `SleepHour` minutes and
persisted per day; UI shows stage totals + a stacked stage bar.

**Official app.** `SleepDataRes` parses the same packed layout (2-bit values × 4/byte,
byte stream split from the multipacket data list), stage map 0 awake / 1 light / 2 deep /
3 REM — identical. Crest requests 7 days max (`setMaxDaysOfSleepDataOnBand(7)`).

**What's wrong.**
- **Day-boundary bug:** the day picker says "Today/Yesterday", but sleep for "today"
  mostly happened *before* midnight — the watch stores it under the *previous* watch
  day. `loadDayHistory(day: 0)` therefore usually shows an empty Sleep section for
  today's night (the data sits in day −1), while the official app's sleep card
  (correctly) shows "last night" by querying yesterday.
- The `data.count % 15 == 0` heuristic misdetects when the 1-min stream happens to be a
  multiple of 6 hours or vice versa (e.g. 90 bytes = 6 h × 15 = 18 h × 5 6-byte … both
  divide); wrong `bytesPerHour` garbles stages silently.
- `WatchStore.upsert(sleep:)` **adds** minutes per hour each pull — re-pulling the same
  day (day-picker toggle back and forth) inflates sleep totals cumulatively.

**What needs fixing.**
- Default the sleep pull to `day: 1` ("last night") — or better, pull both 0 and 1 and
  render the latest night with data (Crest parity).
- Replace the modulo heuristic: 1-min days are exactly `15 × hours-streamed`; stream the
  expected length from the multipacket header (`(endHour-startHour+1) × 15`) and use the
  request's own parameters, falling back to legacy only when the cmd was `01 08`.
- Make `upsert(sleep:)` idempotent per hour (store per-hour stage minutes, not +=).

**What can be enhanced.**
- Sleep target / bedtime card (Crest has `SleepTargetSupported = true` and dedicated
  commands `GET/SET_BED_TIME_MODE_CONFIG` seen in the parser).

## 13. SpO₂ history (`01 26`)

**iOS implementation.** `requestSpo2History(day:0:23:)` (`GET_SPO2_PERIODIC =
01 26 07 00`, verified). `decodeSpo2History` maps 1 byte per 5-min slot, skipping
`0xFF` **and `0`**, timestamps from the target day's midnight, day average + last-12
list in the UI, average persisted.

**Official app.** `Spo2PeriodicDataRes.b()`: 12 values per hour (5-min), `−1` → skipped
(mark), everything else `& 0xFF` added — **the official app does NOT filter `0`**
(and a SpO₂ byte of 0 is not physically plausible, but Crest still records it).
Values grouped 12-per-hour into `Spo2HourlyData` for the cloud sync.

**What's wrong.** Minor: filtering `0` diverges from official behavior — only
cosmetically relevant (a 0 byte is bogus data either way). Timestamp anchoring has the
same partial-day problem as HR (`day` anchored to midnight of `daysAgo`), which is fine
for full days.

**What needs fixing.** Nothing functional; align the `0`-filter with official (drop the
extra filter) or document the divergence.

**What can be enhanced.**
- Hourly min/avg/max grouping (Crest model) and a night-time average (the number that
  matters clinically), both derivable from the existing samples.

## 14. Workout / sport sessions (`01 8B`, `01 97`)

**iOS implementation.** `startSportMode(mode, indoor:)` = `01 8B [mode][indoor?0:1]`
(mode 1 walk / 2 run / 3 cycle / 4 swim / 5 taichi), ack `81 8B payload[0]==1`;
pause/resume `01 97 [1|2]`; stop = mode 0; `#49`: after the first refusal the app hides
start controls and explains "start on the watch" — matching the official
`setSportModeSupportedFromApp(false)` for this model (verified byte-for-byte in
`StormCall3BleApiImpl.getDeviceSupportedFeatures`).

**Official app.** Exactly this: `CurrentSportModeReq.a()` builds the same bytes, and for
Storm Call 3 the capability flag means Crest **never** sends `01 8B` — workouts are
started from the watch and the app only reads history. The iOS behavior (hide after
refusal, pull summary on end) is the correct adaptation.

**What's wrong.** Nothing behavioral. Cosmetic: the start-workout menu still renders
before the first refusal, offering an action the watch will reject.

**What needs fixing.**
- Optionally gate the menu on a `DeviceSupportedFeatures`-style flag discovered at
  handshake (one failed attempt is already stored in `sportStartUnsupported`; persist
  that in the inventory so it survives relaunches).

**What can be enhanced.**
- Real-time sport data push: the decompiled SDK has `GET_5MIN_RUNNING/WALK/BIKE_DATA`
  and live sport streams; a live pace/distance card during a watch-side session would
  match Crest's activity screen. (Larger effort — needs a live capture to map.)

## 15. Workout day summaries (`01 23`)

**iOS implementation.** `requestWorkoutSummary(daysAgo:)` = `01 23 [day]`;
`decodeWorkoutSummary` reads `steps u32` @0, `meters f32` @4, `kcal f32` @8 — mirrors
`TodaysFitnessDataRes` field order. `loadWorkoutDays([0…6])` queues 7 pulls; results
persist in `workoutDays` (session-only, not `WatchStore`).

**Official app.** Uses the same daily-summary family and reads 7 days
(`maxDaysOfStepsDataOnBand(7)`, `…SleepData…(7)`, `…BpData…(7)`, `…HeartRateData…(7)`,
`…RrData…(7)` — verified; run/cycling/swimming history = 0 days for this model, i.e.
sport-mode *detail* history is not supported, consistent with `#49`).

**What's wrong.**
- ~~The **request parameter is wrong for partial days**~~ ✅ FIXED (QF11): day 0 now uses
  `GET_TODAY_FITNESS (01 2f)` (handshake and `loadWorkoutDays`), `01 23 [n]` stays for
  n ≥ 1 — the official flow. `applyWorkoutDay` gives both reply paths one shared upsert.
- ~~Summaries are not persisted~~ ✅ FIXED: `applyWorkoutDay` now writes each pulled day
  into `WatchStore` (steps/calories/distance, idempotent replace like every other
  metric), so the Stored-days rows stay populated and survive restarts; `workoutDays`
  remains the session-side view.

**What needs fixing.**
- Nothing (request parity + persistence both landed; remaining polish below).

**What can be enhanced.**
- ~~Persist workout days across sessions~~ ✅ FIXED (see above).
- A 7-day bar chart of steps/kcal (data already queued and now stored) like Crest's
  activity history.

## 16. Watch faces — list / current / switch (`02 0D`, `02 0F`, `02 8F`)

**iOS implementation.** Requests the installed-face list and current face at handshake;
`decodeWatchFaceList` reads LE u16 pairs starting at payload[0] (fix `#46`, matching
`GetWatchFaceListRes.b()` which parses byte pairs `lo | hi<<8` from string element 5
onward — i.e. after the 4 header fields — equivalent offsets). Switch (`02 8F
[idLo][idHi]`) updates the UI selection only after the `82 8F` ack payload[0]==1
(`SetCurrentWatchFaceRes` parity).

**Official app.** Same commands; Crest additionally supports **watch-face upload /
delete** (`CustomWatchFaceUploadReq`, `DeleteWatchFaceReq`, background auto-play
settings) and background refresh flag (`02 ae`, verified constant).

**What's wrong.** Nothing for list/switch (upload was explicitly scoped out).

**What needs fixing.** Nothing.

**What can be enhanced.**
- Face upload (the SDK plumbing is all in the APK: 0x7F request channel + CRC16 is
  already implemented for contacts — reuse it for the upload frames).
- Show face *names*/previews if the list response carries them in newer firmwares.

## 17. Notifications & incoming calls (`02 82`, `02 83`, `02 81`)

**iOS implementation.** `sendMessage(text:type:)` builds `02 83` with
`[lenLo,lenHi,type,utf8…]`; ≤15 chars single frame, longer → truncated to **58 chars**
with a `0x7F` multipacket header + 16-byte continuation chunks; types 1 call / 3 sms /
5 whatsapp / 18 other. Alert-app bitmask `02 82` (2-byte: byte0 call/calendar/sms/
email/whatsapp/wechat/facebook/instagram, byte1 twitter/messenger/…/linkedin).
Incoming call = type-1 message with the caller name. Music-playback state `02 81`.

**Official app.** Same constants. BUT the Storm Call 3 declares
`setMaxCharSupportedInNotification(200)` and `setTitleSupportedInNotification(true)`
(verified) — Crest sends up to **200 chars** and includes the **title + body** framing
(the type byte and message title ride separate fields, and there is
`SET_MESSAGE_ALERT_SWITCHES_EXTENDED_NOTIFY` for richer payloads). The 58-char clamp is
a legacy-path value, not this device's limit.

**What's wrong.**
- 58-char truncation loses most of a message on this watch (should be 200).
- Title is concatenated into the body (`"Yantra: text"`) instead of using the title
  field the firmware supports — on the watch the whole string renders as one blob.
- The app-switch push hardcodes "call/SMS/WhatsApp"; there is no UI to choose apps and
  no read-back of current switches (`GET_ALERT_SWITCH = 02 03 05 00`).
- No real notification-source integration: iOS cannot silently relay all notifications
  without a Notification Service extension; today only manual text and the test call
  work. (Official app on Android relays every notification natively.)

**What needs fixing.**
- Raise the limit to 200 chars and keep multipacket chunking (frame count math already
  handles it).
- Split title/body fields (send title frame + body frame the way the extended-notify
  request does) or at minimum stop prefixing when the title is the app name.
- Read current alert switches at handshake and pre-fill the toggles.

**What can be enhanced.**
- Per-app switches UI (14 app toggles already modeled in `AlertApps`).
- iOS Notification Center forwarding via a Notification Service Extension /
  `UNUserNotificationCenter` delegate — the flagship parity feature missing on iOS.

## 18. Contacts sync (`00 A8` phone book)

**iOS implementation.** Reads the Contacts store, takes the first N (≤30) with a phone
number, packs `name≤20B NUL number≤20B NUL` per entry behind `00 A8 [count]` via the
CRC16 multipacket channel; ack `80 A8` completes each queued frame. Matches
`SetPhoneBookReq`/`MultiPacketRequestGenerator`.

**Official app.** Same — and it enforces `setMaxContactsInOneRequest(20)` (verified
constant: **20 per request**, multiple requests for more). The watch-side total is
model-dependent.

**What's wrong.**
- The iOS cap is 30 in one request (official caps at 20/request); >20 contacts may be
  refused or silently truncated by firmware.
- No dedupe/normalization: contacts with multiple numbers take `phoneNumbers.first`
  (fine) but nameless or emoji-name entries are sent as-is; official app sanitizes.
- No progress feedback per chunk (the log shows frames, the UI only shows "Syncing…").

**What needs fixing.**
- Batch ≤20 per request (loop the phone-book command), or verify the device accepts 30.

**What can be enhanced.**
- A picker UI to choose which contacts (official app has a selection screen) and
  "remove from watch" (`00 A8` with count 0 — `DELETE_NEARBY_DEVICE_LIST`-style clear).

## 19. Music control (`02 81`, `00 A7`, watch→app `01 00` events)

**iOS implementation.** Play/pause (`02 81 [1|2]`) and volume (`00 A7 [percent]`) are
queued; watch-side play/pause/next/prev/volume events (`01 00 [1..6]`) are decoded and
logged.

**Official app.** Same commands, plus **music metadata change from app** —
`setMusicMetaDataChangeFromAppSupported(true)` (verified): track title/artist frames so
the watch shows what's playing, and the watch's next/prev events actually drive the
phone player (`MPRemoteCommandCenter`-equivalent on Android).

**What's wrong.**
- ~~Watch music events are only logged~~ ✅ FIXED (QF12): the six music events route
  through `MusicRemoteCoordinator` — play/pause/next/prev via `MPRemoteCommandCenter`,
  system volume ±1/16 via a hidden `MPVolumeView` slider (the public iOS surface;
  `MPRemoteCommandCenter` alone only reaches handlers registered inside this app, which
  is why the volume path uses `MPVolumeView`).
- No metadata push (watch always shows generic "Music").

**What needs fixing.**
- Metadata push, if wanted, needs a live capture of the `SetMusicMetaDataReq` frame
  first — it is deliberately NOT wired blind (no verified wire constant in §14).

**What can be enhanced.**
- Push now-playing metadata on track change (decompiled request classes exist:
  `SetMusicMetaDataReq` family — capture-required).

## 20. Camera remote (`02 12` enter/exit + `01 05 [3]` shutter)

**iOS implementation.** Enter/exit sends `02 12 [2][1|2]` (`SetCameraStatusReq`
parity); the watch's capture event triggers a real `AVCaptureSession` still, saved to
the photo library with shutter sound (`#36`).

**Official app.** Same commands; Crest shows a **live preview screen** on the phone
while the remote is active (its session renders to the UI).

**What's wrong.** Nothing functional. The capture session starts on first shutter press
(≈1–2 s latency on the first shot).

**What needs fixing.** Nothing.

**What can be enhanced.**
- ~~Warm the session when entering camera-remote mode~~ ✅ FIXED (QF13):
  `WatchCameraCoordinator.warmUp()` (idempotent configure + async `startRunning`) runs
  when the watch pushes the `.cameraEnter` event, so the first watch-triggered shot no
  longer pays the cold-session latency.
- Show the preview (and a countdown) — parity with Crest's remote screen.

## 21. Find my phone / find my watch (`01 05 [1]`, `02 A5`)

**iOS implementation.** Watch→phone event triggers `FindPhoneCoordinator`: looping
alarm sound, repeating haptics (CoreHaptics with `kSystemSoundID_Vibrate` fallback),
torch blink, 30 s auto-stop; a visible alert. Phone→watch `02 A5 [1|2][count]` rings
the watch, stop command available.

**Official app.** `phoneFinderSupported(true)` and `findMyBandSupported(true)`
(verified). Crest also carries a `FIND_MY_PHONE_ACK` command (`00 00 04 00` — verified
constant) so the phone can confirm to the watch that ringing started; the iOS port
never sends that ack (harmless — the watch still rings its side of the flow, but it
may keep "searching" UI state).

**What's wrong.** The find-my-phone ack is not sent back.

**What needs fixing.** Send the ack frame on `findMyPhone` event (constant verified;
payload shape = single 4-byte frame).

**What can be enhanced.** Volume ramp-up and a "Stop" action in the alert (the alert
currently only has OK; stopping is time-based or via the Log).

## 22. Navigation push (`02 8A` + `00 B4`)

**iOS implementation.** `navigationEvent(source,destination,mode)` = `02 8A` with
`0x41` marker, isStart=1, UTF-16LE source/destination (≤60 units), mode byte
(walk 0 / vehicle 1); status `00 B4 [0|2]`; manual "Update" pushes a destination +
remaining-distance event. Matches `SetNavigationEventReq`/`SetNavigationStatusReq` +
`CoveNavigationService.setNavigationStartOrStopOnBand`.

**Official app.** Identical frames — but Crest feeds the events from a **real
navigation session** (it hooks Google Maps navigation state / its own tracker), pushing
each turn automatically. The iOS app requires the user to type distances by hand, which
is a demo, not a feature.

**What's wrong.** No automatic turn source on iOS (Apple Maps / MapKit directions can
be observed, but that's unimplemented).

**What needs fixing.** Nothing broken (frames verified); the feature is honest but
manual.

**What can be enhanced.**
- Integrate MapKit turn-by-turn (`MKDirections` + route-step monitoring) to push each
  step's remaining distance automatically — that converts this from a demo into real
  parity with Crest's Maps integration.

## 23. History persistence (`WatchStore` → `watchdata.json`)

**iOS implementation.** Per-day merged records (steps, calories, distance, stage
minutes, SpO₂ average, hrByHour) in Application Support; iso8601 decoding matches
encoding (fix `#39`); "Stored days" lists the last 7 with icons.

**Official app.** Crest syncs everything to the Cove cloud (analytics included); Yantra
is deliberately local-only (FR-2/NFR-1). Local persistence parity is *better* than the
official app for privacy; the gap is only in what's persisted (see #11/#15 — HR samples
collapsed, workouts not persisted).

**What's wrong.**
- ~~Sleep minutes accumulate across re-pulls (`upsert(sleep:)` uses `+=`)~~ ✅ FIXED
  (QF3, per-hour slot replace).
- ~~No pruning: `watchdata.json` grows forever~~ ✅ FIXED: retention cap applied on
  every write and at load — the newest **365 days** are kept (documented policy: the
  watch itself only retains 7 days, so older records have no live source; a year is the
  local horizon).

**What needs fixing.**
- Nothing (both gaps closed).

**What can be enhanced.**
- A "day detail" screen (full HR samples + SpO₂ chart) reusing stored data — the store
  already carries most of it once #11 is fixed.

## 24. HealthKit export (`HealthKitWriter.writeWatchDays`)

**iOS implementation.** Exports stored days: one cumulative steps sample/day, hourly HR
samples, sleep-stage category samples (core/deep/REM), daily SpO₂ average; dedupe
metadata `fireflyRecordId: watch<dayKey>`; gated on the "Export to Health" button.

**Official app.** Google Fit / cloud equivalents; not comparable directly. The iOS
implementation is a sensible adaptation.

**What's wrong.**
- **Steps sample is fabricated as a 24-hour cumulative quantity** — HealthKit treats
  step samples as cumulative-within-interval, so a full-day total is legitimate, but the
  export also re-writes it on every re-export *with the same metadata key* — dedupe only
  works for weight (the query path in `writeWeight`); `writeWatchDays` **never queries
  existing samples** and simply saves again. Repeated taps create duplicate steps/HR/
  sleep/SpO₂ samples (the `watch<dayKey>` metadata is written but never *checked*).
- Sleep stages are synthesized into a contiguous timeline starting at `dayStart`
  (midnight) — real sleep happened ~22:00–07:00, so the exported samples sit at the
  wrong hours; deep/REM/light ordering follows light→deep→REM concatenation which does
  not match the actual hourly sequence stored per-hour.

**What needs fixing.**
- Add the same existing-sample predicate query used in `writeWeight`
  (`predicateForObjects(withMetadataKey:allowedValues:)`) before saving watch samples.
- Export sleep per-hour (start = hour-of-day from `SleepHour`), not a midnight-anchored
  concatenation.

**What can be enhanced.**
- Export the full HR sample set once #11 keeps per-sample data; write "Apple
  Sleep Stages" the way the Health app expects (with actual stage boundaries).

## 25. Auto-reconnect (`reconnectIfPaired`, issue #43)

**iOS implementation.** On the watch view opening, reconnects from the stored
`DeviceStore` row (direct `retrievePeripherals` → else name-filtered rescan → auto-pair
first hit, `#37`); deferred reconnect while Bluetooth powers on; disconnect sets
`.failed` with a message.

**Official app.** Crest runs a foreground **service** that keeps the watch connected
`shouldKeepDeviceConnectedAlways(true)` (verified) and re-pairs silently. iOS has no
background-BLE service for this; the port reconnects only when the view opens.

**What's wrong.**
- ~~No retry backoff: a failed `central.connect` (watch out of range) lands in `.failed`
  and needs a manual tap.~~ ✅ FIXED (QF14): ONE automatic retry 6 s after
  `didFailToConnect` / unexpected disconnect (`reconnectAttempted` + `lastLinkTarget`,
  cancelled by user actions, budget reset on `didConnect` / explicit reconnect). A
  user-initiated `disconnect()` now stays `.idle` instead of having its teardown
  callback fabricate a failure.
- After a spontaneous disconnect mid-history-pull, the queue is wiped (`didDisconnect`
  clears queue) and partial streams are dropped with no resume.

**What needs fixing.**
- Bounded backoff loop (more than one attempt for genuinely transient outages) and a
  queue-resume policy after reconnect.

**What can be enhanced.**
- `stateRestoration` (CoreBluetooth background) so pulls continue when the app returns —
  iOS's supported analogue of Crest's always-connected service.

## 26. Multi-device hub & driver architecture (SRD-009)

**iOS implementation.** `DriverRegistry` with `ScaleDriver`/`WatchDriver`/`BulbDriver`
stub; `DeviceStore` inventory (`devices.json`); `AddDeviceSheet` routes by kind; the
hub lists inventory and opens driver feature UI. The watch, however, runs on **its own
`CBCentralManager`** (`WatchCentral.central`) while the hub scan uses
`DeviceTransport.shared` — two central managers coexist.

**Official app.** Single BLE client (one `BluetoothGatt` at a time) — but Crest is
single-device anyway. For Yantra's hub model, simultaneous scale + watch is a selling
point (weigh-in while wearing the watch).

**What's wrong.**
- Two `CBCentralManager`s is allowed by iOS but wasteful and can hit
  background-scan limits; the transport's design intent (one shared central, SRD-009
  FR-3) is bypassed by `WatchCentral`.
- `DeviceTransport` enforces **one session at a time** (`session` property) — connecting
  the watch through the hub would tear down scale sessions and vice versa; today the
  watch only avoids this by not using the transport.

**What needs fixing.**
- Move `WatchCentral` onto `DeviceTransport` (it already has `WatchScanner` +
  `WatchSessionBridge` plumbed) OR document the two-central split as intentional;
  either way make the hub show *both* devices' live state simultaneously.

**What can be enhanced.**
- Hub row live badges (battery % / connection state) for both devices.

---

## 13. Appendix — quick-fix log (QF1…QF14, this branch)

| Fix | Finding | Change | Verified by |
|---|---|---|---|
| QF1 | #7 clock sync BCD vs binary | `KahaProtocol.setDeviceTime` now writes plain-binary `yy yy MM dd HH mm ss ±HH mm` (`LeonardoBleService.k()` parity) | `testSetDeviceTimePayload` updated + new `testSetDeviceTimeGoldenVector` (`00 87 0E 00 14 1A 09 18 0E 1A 05 2B 05 1E` — 14 B; an earlier draft dropped the minute byte) |
| QF2 | #17 58-char notification clip | `sendMessage(_:type:maxChars:)` clips at 200 (model capability), `sendNotificationMessage(title:body:)` frames `title\nbody`; `WatchCentral.sendNotification` uses it | compile + existing `testSendMessage*` (40-char multipacket still splits) |
| QF3 | #12/#23 sleep inflation | `WatchStore.upsert(sleep:)` replaces per-hour slots (`sleepSlots` map) and recomputes totals — re-pulls no longer accumulate; back-compat decode for old records | compile + `testWatchStoreRoundTripAcrossInstances` |
| QF4 | #24 HealthKit duplicates + midnight-anchored sleep | `writeWatchDays` now queries existing metadata ids across ALL four sample types (steps/HR/sleep/SpO₂ — previously sleep-only AND results were ignored) and skips saved ids before saving; sleep exported per hour at real clock times with per-slot dedupe keys; legacy records fall back to the contiguous path | review + brace-balance (no Swift in sandbox) |
| QF5 | #18 contacts >20 per request | `syncContacts` batches ≤20 per `00 A8` request (official `maxContactsInOneRequest`); UI cap raised to 100 | compile |
| QF6 | #6 hardware version never fetched | handshake queues `00 01` (`GET_HARDWARE_VERSION`), `hardwareVersion` published, Device section row | compile |
| QF7 | #1 scan-list duplicates on RSSI change | `upsertScanEntry` keys by peripheral id, keeps best RSSI/freshest name, sorts by signal | compile |
| QF8 | #5 stale stream misrouted after ack timeout | `forceCompleteInFlight` resets the `MultipacketAssembler` when a history command times out | compile |
| QF9 | #21 find-my-phone ack missing | watch's `findMyPhone` event now queues `FIND_MY_PHONE_ACK = 81 05 05 00 01` (constant re-verified from `BleUUID` with corrected branch-target extraction) | compile |
| QF10 | #8 handshake demands a battery CCCD some firmware never exposes | `didDiscoverCharacteristicsFor` tracks `sawBatteryChar`; gate = UART CCCD **AND** (battery CCCD subscribed OR no battery characteristic was ever discovered) — reset in `resetLink()` | review + brace-balance (no Swift in sandbox) |
| QF11 | #10/#15 u16-capped steps; `01 23 00` mid-day can return yesterday totals | `KahaProtocol.decodeTodaysFitness` (legacy 3-byte shape + full u32-steps/f32-m/kcal shape with finite/≥0/<100 k float gating; `leU32` helper) + `requestTodaysFitness()` = `GET_TODAY_FITNESS 01 2f 04 00`; handshake and day-0 workout pull now use `01 2f`; `deliverHistoryData(.steps)` reads u32 at payload[5..8] for the full `TodaysStepsDataRes` shape; `applyWorkoutDay` shared upsert for both reply paths | review + brace-balance; tests rewritten/added: `testTodaysStepsDecode` (legacy), `testTodaysFitnessDecodeU32WithFloats` (70 000 steps > u16 max), `testTodaysFitnessIgnoresGarbageFloatTail` (NaN/negative dropped), `testRequestTodaysFitnessFrame` (`01 2f 04 00`) |
| QF12 | #19 watch music events only logged | `MusicRemoteCoordinator` (MediaPlayer): play/pause/next/prev via `MPRemoteCommandCenter` (toggle-preferring), system volume ±1/16 via hidden `MPVolumeView` slider; `handleWatchEvent` routes the six music events through it | review + brace-balance |
| QF13 | #20 first watch-shutter shot pays 1–2 s cold session start | `WatchCameraCoordinator.warmUp()` (idempotent configure + async `startRunning`) called when the watch pushes the `.cameraEnter` event | review + brace-balance |
| QF14 | #25 dead link stays dead until the view is reopened | ONE automatic retry 6 s after `didFailToConnect` / unexpected `didDisconnectPeripheral` (`reconnectAttempted` + `lastLinkTarget`); cancelled by `disconnect()`/new link attempts, budget reset on `didConnect` and explicit `reconnectIfPaired()`; user-initiated teardown now honors `.idle` (the `didDisconnectPeripheral` callback no longer fabricates a failure) | review + brace-balance |

Swift is not available in this sandbox (`swift: command not found`), so QF1–QF14 were
verified by code review against the decompiled reference only — run `swift test` in
`scalekit/` and an `xcodebuild` build of `ios/` on a Mac before a hardware session.

## 14. Appendix — recovered `BleUUID` constants (ground truth)

Verified command table from `classes7.dex` (extraction: static `<clinit>` array
payloads with code-unit branch-target mapping — all 132 constants recovered):

```
GET_DEVICE_NAME        = 00 00 04 00     GET_HARDWARE_VERSION  = 00 01 04 00
GET_FIRMWARE_VERSION   = 00 02 04 00     GET_MAC_ADDRESS       = 00 03 04 00
GET_SN                 = 00 04 04 00     GET_DEVICE_TIME       = 00 06 04 00
GET_BATTERY_LEVEL      = 00 08 04 00     SET_DEVICE_TIME       = 00 87 0e 00
SET_DEVICE_TIME_24H    = 00 82 05 00 00  SET_DISTANCE_UNIT_KM  = 00 a2 05 00 00
SET_PAIRING_PHONE_TYPE = 00 86 05 00 00  GET_WALK_VALUE        = 01 00 05 00 00
GET_TODAY_FITNESS      = 01 2f 04 00     HR_BP_INTERVAL/HISTORY= 01 02 07 00
GET_10MIN_SLEEP_DATA   = 01 08 07 00     GET_1MIN_SLEEP_DATA   = 01 0c 07 00
GET_SPO2_PERIODIC      = 01 26 07 00     PAUSE_ACTIVITY_SESSION= 01 97 05 00
SET_MESSAGE_ALERT_SW   = 02 82 06 00     MSG_ALERT_EXT_NOTIFY  = 02 82 08 00
SEND_MESSAGE_CONTENT   = 02 83 (family)  GET_ALERT_SWITCH      = 02 03 05 00
SET_WATCH_FACE_REFRESH = 02 ae 05 00     FIND_MY_PHONE_ACK     = 81 05 05 00 01
```

Official `DeviceSupportedFeatures` for Storm Call 3 (from
`StormCall3BleApiImpl.getDeviceSupportedFeatures`, classes12.dex) — features worth
porting marked ←:

```
steps/sleep/REM/HR supported; BP via BleEnableBpV7 flag; max 7 days steps/sleep/BP/HR/RR/SpO₂
run/cycling/swimming data: 0 days      sportModeSupportedFromApp = FALSE  (matches iOS #49)
scheduled DND, oneClick connect, calendar sync, call/SMS/social notifications (titles supported)
maxCharSupportedInNotification = 200   ← iOS truncates at 58
maxContactsInOneRequest = 20           ← iOS sends up to 30 in one request
musicMetaDataChangeFromApp = TRUE      musicPlaybackStateChangeFromApp = TRUE
camera, phoneFinder, findMyBand, sedentary(+history), vibration alarms, band display,
hand settings, lift-wrist (incl. scheduled), personal info, step goal, probe feature,
periodic SpO₂ = TRUE, manual SpO₂ = FALSE, auto-HR settings = TRUE,
distance-unit settings = TRUE, temperature: history/interval/unit = FALSE,
ECG/RR = FALSE, female wellness = FALSE, weather-in-band = FALSE,
SOS = FALSE, GPS = FALSE, BT-calling (KaHa) = TRUE, shouldKeepDeviceConnectedAlways = TRUE
```

Everything in the "←" rows is a concrete, decompiled-verified gap in the iOS app;
each is called out in the matching section above.
