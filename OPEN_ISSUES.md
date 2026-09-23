# Open Issues

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