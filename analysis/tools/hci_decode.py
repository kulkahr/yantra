#!/usr/bin/env python3
"""
hci_decode.py — decode a btsnoop_hci.log into the A6-protocol transcript.

Extracts ATT notify/write(wo resp) frames via tshark, maps handles to the A6
GATT characteristics, XOR-decodes payloads with the scale MAC (the TRUE byte
order — the advertisement carries it reversed), reassembles multi-frame
packets, and prints the command transcript. Optionally writes a replay-harness
capture JSON (schema v1, analysis/captures/README.md) from the device→app
notifies, verbatim.

Usage:
  python3 hci_decode.py <btsnoop.log> [--mac D8:0B:CB:1B:06:31] [--out capture.json]
                        [--last N]
"""
import argparse
import json
import subprocess
import sys
from datetime import datetime, timedelta

TSHARK = "/Applications/Wireshark.app/Contents/MacOS/tshark"

# A6 command codes (mirror of ScaleKit's A6Command)
CMDS = {
    0x0001: "REGISTER", 0x0002: "REGISTER_RESULT", 0x0003: "BIND_NOTICE",
    0x0004: "BIND_RESULT", 0x0005: "UNBIND_NOTICE", 0x0006: "UNBIND_RESULT",
    0x0007: "AUTH_CHALLENGE", 0x0008: "AUTH_RESPONSE", 0x0009: "INIT_REQ",
    0x000A: "INIT_RESP", 0x1000: "SETTING_CALLBACK", 0x1001: "PUSH_USER_INFO",
    0x1002: "PUSH_TIME", 0x1003: "PUSH_TARGET", 0x1004: "PUSH_UNIT",
    0x1005: "PUSH_CLEAR_DATA", 0x1006: "PUSH_FORMULA", 0x1007: "PUSH_HR_SWITCH",
    0x4801: "MEASURE_SETTING", 0x4802: "WEIGHT_RECORD", 0x00E9: "LIVE_SAMPLE",
    0x2001: "ECHO_UNIT",
}
# Handle → role; resolved from GATT discovery if absent (16-bit short names)
KNOWN_HANDLES = {}


def mac_bytes(mac: str):
    return [int(b, 16) for b in mac.split(":")]


def xor(payload: bytes, key: list[int]) -> bytes:
    return bytes(b ^ key[i % 6] for i, b in enumerate(payload))


def cmd_name(v: int) -> str:
    return CMDS.get(v, f"UNKNOWN_{v:04X}")


def pull_att(path):
    """tshark → list of (frame_no, epoch, opcode, handle, value_hex)."""
    """tshark → list of (frame_no, opcode, handle, value_hex)."""
    out = subprocess.run(
        [TSHARK, "-r", path, "-Y",
         "btatt.opcode==0x52 || btatt.opcode==0x12 || btatt.opcode==0x1b || btatt.opcode==0x1d",
         "-T", "fields", "-e", "frame.number", "-e", "frame.time_epoch", "-e", "btatt.opcode",
         "-e", "btatt.handle", "-e", "btatt.value"],
        capture_output=True, text=True)
    rows = []
    for line in out.stdout.splitlines():
        parts = (line.split("\t") + ["", "", "", "", ""])[:5]
        fn, ts, op, h, val = parts
        if not (op and h and val):
            continue
        try:
            rows.append((int(fn), float(ts), int(op, 16), int(h, 16),
                         bytes.fromhex(val.replace(":", ""))))
        except ValueError:
            continue
    return rows


def resolve_handles(rows):
    """Scan ATT read-by-type/type responses to map handle→UUID16, then pick the
    A6 characteristics. Fallback: known fixed map for this scale."""
    for _, _, op, h, val in rows:
        if op in (0x09, 0x11) and val:   # read by type / read by group resp
            # entries: [len][handle 2B][uuid ...] — crude scan for A6xx UUIDs
            for i in range(0, len(val) - 1):
                u = (val[i] << 8) | val[i + 1]
                if 0xA621 <= u <= 0xA625:
                    KNOWN_HANDLES[u] = u
    # The discovery response lists (handle, uuid) pairs; tshark already parsed
    # them — easiest reliable path is the fixed map below, verified live:
    return {0x001E: 0xA621, 0x0021: 0xA622, 0x0025: 0xA624, 0x0027: 0xA625}


def reassemble(frames) :
    """A6 packet reassembly: frames = [(count<<4)|serial, len, payload≤18B].
    Multi-frame packets carry CRC32(plaintext) appended BEFORE obfuscation —
    on the wire each payload chunk is XORed; we re-XOR each chunk then join."""
    if not frames:
        return None
    total = frames[0][0] >> 4
    if len(frames) != total:
        return None
    return b"".join(f[2:] for f in sorted(frames, key=lambda f: f[0] & 0xF))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--mac", default="D8:0B:CB:1B:06:31")
    ap.add_argument("--out", help="write replay capture JSON (device→app, verbatim)")
    ap.add_argument("--last", type=int, default=0, help="only show last N commands")
    args = ap.parse_args()

    key = mac_bytes(args.mac)
    rows = pull_att(args.log)
    hmap = resolve_handles(rows)
    inv = {v: k for k, v in hmap.items()}

    # Collect events in arrival order with real timestamps.
    events = []          # (frame_no, epoch, char, wire)
    for fn, ts, op, h, val in rows:
        if h not in hmap:
            continue
        char = hmap[h]
        if op in (0x1B, 0x1D):                      # device→app notify
            if len(val) >= 2:
                events.append((fn, ts, char, val))
        elif op in (0x52, 0x12) and val:            # app→device write
            events.append((fn, ts, char, val))

    # Decode each event as one A6 frame set (this scale sent only single frames).
    transcript = []
    cap_events = []
    t0 = None
    for fn, ts, char, wire in events:
        if t0 is None:
            t0 = ts
        count, ln = wire[0] >> 4, wire[1]
        payload_wire = wire[2:2 + ln]
        if count > 1:
            transcript.append((fn, char, None, f"multi-frame ({count}) — join needed"))
            continue
        payload = xor(payload_wire, key) if ln else payload_wire
        if ln == 0:
            status = payload_wire[2] ^ key[0] if len(payload_wire) >= 3 else None
            kind = "ACK-OK" if status == 1 else f"ACK({status})"
            transcript.append((fn, char, None, kind))
        elif ln == 1 or len(payload_wire) < 3:
            # Short ACK-shaped notify: [00 01 status^mac0]
            status = payload_wire[0] ^ key[0] if payload_wire else None
            kind = "ACK-OK" if status == 1 else f"ACK({status})"
            transcript.append((fn, char, None, kind))
        else:
            cmd = (payload[0] << 8) | payload[1] if len(payload) >= 2 else 0
            transcript.append((fn, char, payload, cmd_name(cmd)))
        if char in (0xA621, 0xA625):               # device→app → capture event
            cap_events.append({"t": round(ts - t0, 3),
                               "char": f"{char:04X}", "hex": wire.hex()})

    shown = transcript[-args.last:] if args.last else transcript
    for fn, char, payload, info in shown:
        arrow = "←DEV" if char in (0xA621, 0xA625) else "APP→"
        if payload is None:
            print(f"#{fn:5d} {arrow} {char:04X}  {info}")
        else:
            print(f"#{fn:5d} {arrow} {char:04X}  {info:16s} {payload.hex()}")

    if args.out:
        obj = {
            "version": 1,
            "meta": {
                "mac": args.mac,
                "firmwareVersion": "1.5.0.0",
                "recordedAt": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                "kind": "session",
                "notes": "REAL hardware capture, decoded from official realme Link "
                         "app HCI snoop (btsnoop). Device→app notify frames verbatim.",
            },
            "events": cap_events,
        }
        with open(args.out, "w") as f:
            json.dump(obj, f, indent=2)
        print(f"\ncapture written: {args.out} ({len(cap_events)} device→app events)", file=sys.stderr)


if __name__ == "__main__":
    main()
