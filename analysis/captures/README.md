# Captured BLE notify sequences — replay format

Phase 0 leftover: replay the state machines on **recorded** device traffic (not just the
synthetic `DeviceSimulator`). This folder holds captures; this file defines the format.

## How to capture (experiments E1 / E2)

The recorder is built in: **`a6host`** (Phase 1 CLI, `scalekit/Sources/A6Host/`). It logs
every notify exactly as it arrives — unmodified — and writes a capture on success, abort,
timeout, or Ctrl-C.

```bash
cd scalekit
BUILD=.build/debug/a6host

# 0) wake the scale (step on it briefly), then discover + persist identity:
$BUILD scan --duration 15

# 1) E1 — full pair/bind handshake (closes unknown U1):
$BUILD pair --slot 1 --notes "first bind from macOS"

# 2) E2 — session: init → config pushes → live weigh-in → history drain (U2):
$BUILD session --slot 1 --arm --notes "weigh-in, barefoot, compare vs realme Link"

# persisted state:
$BUILD status
```

Captures land next to this README as `pair_<timestamp>.json` / `session_<timestamp>.json`
(git-commit them: text-only, no personal data beyond the scale's public MAC + the recording
user's weight values — rename/scrub if that matters). To replay one against the state
machines, drop it into `scalekit/Tests/ScaleKitTests/` and load it via
`BleReplayPlayer.load(...)` — same schema, no conversion needed.

Manual recorder reference (CoreBluetooth), if the CLI needs re-verification:

```swift
func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
    guard let d = c.value else { return }
    log.append([
        "t": Date().timeIntervalSince(sessionStart),          // seconds since connect
        "char": c.uuid.uuidString,                             // "A621" / "A625" (short form)
        "hex": d.map { String(format: "%02X", $0) }.joined(),  // RAW notify bytes, verbatim
    ])
}
```

## JSON schema (v1)

```jsonc
{
  "version": 1,
  "meta": {
    "mac": "31:06:1B:CB:0B:D8",       // scale MAC as advertised (coloned form)
    "firmwareVersion": "1.5.0.0",     // from 180a:2A26 — picks the XOR variant for replay
    "recordedAt": "2026-09-21T08:00:00Z",
    "kind": "pair" | "session",       // which machine to replay against
    "notes": "free text: what was done during the capture"
  },
  "events": [
    { "t": 0.412, "char": "A621", "hex": "1C12..." },   // device → app data notify
    { "t": 0.441, "char": "A625", "hex": "0001 39" },   // device → app ACK notify
    { "t": 0.905, "char": "A621", "hex": "1C12..." }
  ]
}
```

Rules:

1. **Events are device→app only** (everything that arrived on `A621`/`A625` notifies).
   App→device writes are *derived* by replaying the machine and asserted separately.
2. **`hex` is verbatim wire bytes** — never re-chunked, de-obfuscated, or reordered.
   The whole point is to test our assumptions, so the capture must not encode them.
3. Multi-frame packets appear naturally as consecutive notify events; the replay feeds
   them to the machine in order, just like CoreBluetooth would.
4. `t` is informational (ordering is positional); gaps > 3 s between an expected write
   and the next event indicate a resend would have fired on real hardware.

## How replay works (BleReplayPlayer)

`BleReplayPlayer` (in `scalekit/Tests/ScaleKitTests/BleReplayPlayer.swift`) loads a capture,
constructs the appropriate state machine from `meta`, and pumps each event as a
`LinkEvent.notifyData(characteristic:data:)`. Everything the machine emits as
`LinkAction.write` is recorded; `LinkAction.connect/discover/...` are auto-acknowledged
with the canned `LinkEvent` sequence the real host would produce. The test then asserts
on machine phase transitions and emitted writes (e.g. "an auth response 0x0008 was written
after the 0x0007 challenge", "ACK-ok written to A622 for every assembled packet").

## Status

- [x] Format defined (this file)
- [x] `BleReplayPlayer` + synthetic-capture round-trip test (proves the harness itself)
- [x] Recorder built: `a6host` CLI (scan/pair/session/replay modes, signal-safe capture save)
- [x] **Real ground-truth capture via the official app** (2026-09-21): Android **Bluetooth HCI
  snoop log** from the paired phone during real weigh-ins → decoded with
  `analysis/tools/hci_decode.py` (btsnoop → A6 transcript + replay-format capture).
  `hci/` subfolder holds the raw logs + `session_realweighin.json` (54 device→app events
  incl. a full 45-record history drain). **Note:** that folder is gitignored (the btsnoop
  contains the phone's Bluetooth traffic); regenerate via `hci_decode.py` from a fresh
  bugreport if needed. This capture is the replay-harness falsification step: it exposed
  and settled the init-response shape, 0-based measure slot, tz-code formula, and the
  real config-push set (see FUTURE_PLAN Phase 1).
- [ ] Direct pair capture from the Mac (`a6host pair`) — blocked on the scale's
  introduction ritual: it never challenges an unknown BLE peer (see FUTURE_PLAN E1 notes).
- [ ] Live-stream frame classification (**U2**): weigh-ins so far emitted final `0x4802`
  records only; `0x00E9` live samples still unobserved on this firmware.
