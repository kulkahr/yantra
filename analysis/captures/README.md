# Captured BLE notify sequences — replay format

Phase 0 leftover: replay the state machines on **recorded** device traffic (not just the
synthetic `DeviceSimulator`). This folder holds captures; this file defines the format.

## How to capture (experiments E1 / E2)

Run the macOS CLI harness (Phase 1, `analysis/tools/`) against the physical scale and log
every notify exactly as it arrives — unmodified. Minimal CoreBluetooth recorder loop:

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

Save as `<name>.json` next to this README and git-commit it (captures are small, text-only,
and contain no personal data beyond the scale's public MAC + weight values of the recording
user — rename/scrub if that matters).

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
- [ ] Real pair capture from the physical scale (needs experiment **E1**, Phase 1)
- [ ] Real weigh-in capture (needs experiment **E2**; will settle unknown **U2**)
