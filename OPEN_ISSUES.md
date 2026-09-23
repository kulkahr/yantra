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
