# REPLICATION.md — bind a fresh scale and stream weigh-ins from the Mac

Hardware-verified runbook (2026-09-21, realme Smart Scale LS213-B, firmware 1.4.0.42).
Everything below was executed live against the physical scale — **no realme Link app,
no cloud, no account, no BLE bonding involved.** This is the exact recipe behind the
E1″/E2″ results in `docs/FUTURE_PLAN.md`.

---

## 0. Prerequisites

```bash
# macOS 14+ with Xcode installed; build once:
cd scalekit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
# sanity: suite must be green (33 tests)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

**Before touching the scale:**

1. **Close realme Link on every phone** (swipe away / `am force-stop com.realme.link`).
   A rival app holding the connection makes the scale non-connectable or steals the
   measurement stream.
2. **Know the scale's sleep behavior** — it advertises only when active:
   - stepping ON/OFF wakes it → advertises ~10–20 s,
   - it stays connected ~30–90 s when idle, then drops the link (normal, not an error).
3. Identify the MAC first (also verifies advertisement decoding):

```bash
.build/debug/a6host scan --duration 12
# → realme Smart Scale | id <UUID> | rssi -6x | mfg 1234567801<MAC-reversed>
# mfg `...0131061bcb0bd8` ⇒ MAC D8:0B:CB:1B:06:31 (trailing 6 bytes, reversed)
```

> `deviceId = lowercase MAC without separators` (e.g. `d80bcb1b0631`). The scale
> derives it the same way; the challenge's verification code is all-zeros.

---

## 1. Bind the Mac to the scale (E1 — one time)

**Timing is the whole game.** Step **OFF** the scale (its post-measurement advertise
window is the easiest to catch), launch the command below within a few seconds, and
have someone ready to step ON **only after** the log prints `pair machine started`.

```bash
cd scalekit
.build/debug/a6host pair --slot 1 --mac "D8:0B:CB:1B:06:31" --fast
```

- `--fast` skips the 180a/A641 reads (they stall ~5 s on this firmware — fatal when
  racing the advertise window). The fw default `1.5.0.0` (XOR variant) is applied
  automatically; the wire itself confirms the variant (only correctly-XORed commands
  get ACKed).
- `--slot 1` claims user slot 1. Use 2–5 to add additional users.

Expected transcript (abbreviated from the successful 13:40 run):

```
GATT connected — discovering services …
  char A620: {read,indicate}          ← MUST be present (see "wire facts" below)
  char A621: {read,notify}
  ...
enabling notifications on A620, A621, A625 …
pair machine started (fw 1.5.0.0, xored=true)
→ write A624 1009D80A1310CD2ADE3ACA (no-response)   # 0x0001 register [MAC][state]
← A621 100AD80CCB1B0631D80BCB3A                     # 0x0007 challenge (code zeros)
→ write A624 100BD803CA1B0631D80BCB1A04 (no-response) # 0x0008 auth, mode 1 = bind
→ write A624 1004D808CA1A (no-response)             # 0x0003 bind notice [slot][user]
← A621 1003D80FCA                                   # 0x0004 bind result = 1 = SUCCESS

E1 RESULT: BOUND ✓
  deviceId = D80BCB1B0631
```

The bind is persisted to `~/Library/Application Support/a6host/bind.json`
(`a6host status` shows it). The scale now whitelists the Mac forever — it will
challenge us spontaneously on every future connect.

---

## 2. Live weigh-in streaming (E2)

**Order matters: the Mac must be fully connected BEFORE the user steps on.** The scale
assigns the measurement to the connection that existed when the measurement began.

```bash
.build/debug/a6host session --slot 1 --mac "D8:0B:CB:1B:06:31" --fast --arm
```

- `--arm` sends `0x4801 [slot][1]` (start-measurement) right after the handshake.
  **Without it the scale completes the handshake happily but never sends a single
  record** — this is the phone's behavior exactly, and the #1 thing to forget.
- `--timeout N` extends the window (default 180 s).

Procedure:

1. Step **OFF**, launch the command.
2. Wait for `session machine started` (~3 s: connect → discovery → 4 CCCDs → handshake).
3. Step **ON**, stand still through weight → body scan → **heart-rate phase**
   (the HR phase is when impedance/HR fields finalize in the record).
4. Step off; the run ends after the idle drop or `--timeout`.

Expected transcript (real 14:26 weigh-in — 4 records, remain 3→0):

```
← A621 100AD80CCB1B0631D80BCB0D    # spontaneous 0x0007 challenge — we're whitelisted
→ write A624 100BD803CA1B0631…     # 0x0008 login (mode 0)
← A621 1003D802D3                  # 0x0002 register-result = 1
→ write A624 1008D801D371B6…       # 0x000A init response (UTC + tz)
→ write A624 100BC80ACA1B27…       # 0x4801 measure-setting  ← --arm
→ write A624 1003C80FCB            # 0x1001 user-info push
→ write A624 1004900ACB1A          # 0x1004 unit push
✔ record: 70.75 kg (remain 3, unit 0, impedance 600)
✔ record: 70.8 kg  (remain 2, unit 0, impedance 604)
✔ record: 70.75 kg (remain 1, unit 0, impedance 601)
✔ record: 70.75 kg (remain 0, unit 0, impedance 585)

E2 RESULT: live · records: 4
```

Each `0x4802` record arrives **in real time during the weigh-in** (this firmware has
no separate live-stream frame — the records ARE the live stream; U2 closed).

---

## 3. Drain a stored measurement (weigh-in happened while disconnected)

Missed the window? The record sits onboard. Do a fresh weigh-in (or step on briefly),
then **launch the session command while stepping off** — the post-measurement
advertise window is the reliable catch:

```bash
.build/debug/a6host session --slot 1 --mac "D8:0B:CB:1B:06:31" --fast --arm
# → ✔ record: 70.7 kg (remain 0, unit 0, impedance 500)   # pulled from flash
```

Note: the scale only serves records over a connection with a completed handshake +
`0x4801` arm. An idle connected client gets nothing (verified repeatedly).

---

## 4. Verify & replay

```bash
.build/debug/a6host status                                   # bind store + scan store
.build/debug/a6host replay analysis/captures/session_<TS>.json --mac "D8:0B:CB:1B:06:31"
```

`replay` feeds the saved capture through `SessionStateMachine` — useful to reproduce
a session byte-for-byte after library changes. Every run writes a schema-v1 capture
(`analysis/captures/{pair,session}_<timestamp>.json`); HCI-derived captures decode via
`analysis/tools/hci_decode.py`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `waiting for link setup` forever | Scale asleep (no weigh-in) or held by a rival app | Step on/off to wake; force-stop realme Link on all phones; relaunch |
| Connects, machine starts, **no challenge** | Missing CCCD (esp. A620) or `--fast` off defaulting wrongly | Use current build; check transcript shows `char A620: {read,indicate}` and `enabling notifications on A620, A621, A625` |
| Handshake completes, weigh-in gives **0 records** | Forgot `--arm` (no `0x4801` sent), or user stepped on before `machine started` | Add `--arm`; connect first, step on second |
| `read timeout (2A26, …)` warning | Firmware reads stall on this unit (known) | Harmless with `--fast`; run continues with defaults |
| `link disconnected` after ~30–90 s idle | Normal scale idle policy | Not an error — results print in the summary block |
| `E1 RESULT: NOT BOUND` + only `1003…` frames | Bind accepted (0x0002=1) but challenge never came — old subscribe set, or measurement raced the handshake | Rebuild, retry with the step-off → launch → step-on order |
| Duplicated first command write (`1009…` twice) | 3 s ACK-resend watchdog racing a slow stack | Harmless — scale ACKs both; matches decompiled resend behavior |

---

## Wire facts this runbook depends on (all hardware-verified)

1. **deviceId = lowercase MAC** (`d80bcb1b0631`); challenge verification code is
   all-zeros; auth response just echoes it. No cloud, no secret (U1 closed).
2. **The challenge gate is GATT-level:** the scale challenges peers that subscribe
   **all four** notifiable characteristics — `A620` (indicate), `A621`, `A625`,
   `1531` (OTA). Subscribing only A621+A625 yields silence.
3. **No BLE bonding/SMP** anywhere — plain unencrypted ATT (verified in HCI logs).
4. **A624/A622 are write-without-response only**; app→device ACKs go to A622,
   commands to A624; device data on A621, device ACKs on A625.
5. **`0x4801 [slot-1][1]` must follow the handshake** or records never flow;
   slot byte is 0-based on the wire.
6. **Live stream = real-time `0x4802` records** (obfuscated `0x1011` on the wire);
   no `0x00E9` frames exist on fw 1.4.0.42 (U2 closed).
7. Timezone byte = `(offsetMinutes / 15) + 48` (IST → `0x46`); init response is
   8 bytes `[0A 18 UTC×4 tz]` when the scale's `0x0009` carries flags `0x18`.
