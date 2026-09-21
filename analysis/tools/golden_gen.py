#!/usr/bin/env python3
"""Independent Python port of the decompiled Lifesense A6 codec (truth model).

Generates golden vectors consumed by ScaleKitTests. Every function mirrors the
decompiled Java exactly (realme-scale-re/decompiled/smartscale/sources/com/lifesense/ble/...):
  - DataUtils.crc32 / get_crc32_string
  - DataUtils.getBytesXorResult
  - DeviceDataPackage.formBytes (decode)
  - A6ProtocolParser.generateResponsePackage (encode)
  - A6ProtocolParser.getAckPacket
  - FatScalePairWorker.getDeviceId
  - DataParseUtils.parseWeightDataForA6
"""
import json

MASK32 = 0xFFFFFFFF


# ---------------- CRC32 (decompiled: init_crc_table + crc32) ----------------
def _make_table():
    table = []
    for i in range(256):
        j = i
        for _ in range(8):
            j = (j >> 1) ^ 3988292384 if (j & 1) == 1 else j >> 1
        table.append(j)
    return table


_TABLE = _make_table()


def crc32(data: bytes) -> int:
    """Port of DataUtils.crc32: table-driven, init 0, no final xor."""
    j = 0
    for b in data:
        j = (j >> 8) ^ _TABLE[(b ^ j) & 0xFF]
    return j & MASK32


def crc32_hex(data: bytes) -> str:
    """Port of get_crc32_string: 8 uppercase hex chars, zero-padded."""
    return format(crc32(data), "08X")


# ---------------- XOR (DataUtils.getBytesXorResult) ----------------
def xor_key(data: bytes, key: bytes) -> bytes:
    """XOR with repeating key; key index cycles over key length."""
    return bytes(b ^ key[i % len(key)] for i, b in enumerate(data))


# ---------------- helpers ----------------
def mac_bytes(mac: str) -> bytes:
    return bytes.fromhex(mac.replace(":", "").upper())


def format_with_zero(s: str, n: int) -> str:
    return s.zfill(n)


def to4bytes_short(v: int) -> bytes:
    """DataUtils.to4Bytes(short): 2 bytes big-endian (decompiler name!)."""
    return bytes([(v >> 8) & 0xFF, v & 0xFF])


def to4bytes_int(v: int) -> bytes:
    return bytes([(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF])


# ---------------- encode: A6ProtocolParser.generateResponsePackage ----------------
def encode_packet(payload: bytes, mac: str, xored: bool) -> bytes:
    """Port of A6ProtocolParser.generateResponsePackage(fw, content).

    payload: raw command bytes (already includes 2-byte command header).
    """
    data = payload
    macb = mac_bytes(mac)
    if xored:
        data = xor_key(data, macb)
    hexbuf = data.hex().upper()
    crc = crc32_hex(data)
    if len(hexbuf) > 36:
        hexbuf += crc  # data[36] = crc appended (payload > 18 bytes)
    # chunk into 18-byte (36 hex) frames; header = (count<<4|serial, len)
    total = len(hexbuf)
    frames = []
    i = 0
    while i < total:
        frames.append(hexbuf[i:i + 36])
        i += 36
    count = len(frames)
    out = bytearray()
    for idx, f in enumerate(frames):
        out += bytes([(count << 4) | idx, min(total - idx * 36, 36) // 2])
        out += bytes.fromhex(f)
    return bytes(out)


# ---------------- decode: DeviceDataPackage.formBytes ----------------
def decode_frame(frame: bytes, mac: str, xored: bool):
    """Port of DeviceDataPackage.formBytes for a single frame."""
    if len(frame) <= 2:
        return None
    count = (frame[0] >> 4) & 0x0F
    serial = frame[0] & 0x0F
    length = frame[1] & 0xFF
    payload = bytearray()
    cmd_hex = ""
    if length + 2 <= len(frame):
        if serial == 0 and count != 0:
            # header frame: first 2 payload bytes = packet command (XOR-decoded if gated)
            head2 = frame[2:4]
            if xored:
                mb = mac_bytes(mac)
                head2 = xor_key(head2, mb)
            cmd_hex = head2.hex().upper()
        body = frame[2:2 + length]
        if xored:
            body = xor_key(bytes(body), mac_bytes(mac))
        payload = body
    return {
        "count": count,
        "serial": serial,
        "length": length,
        "command": cmd_hex,
        "payload": bytes(payload),
    }


# ---------------- ACK: A6ProtocolParser.getAckPacket ----------------
def ack_packet(ok: bool, mac: str, xored: bool) -> bytes:
    b = 1 if ok else 2
    if xored:
        b = (b ^ mac_bytes(mac)[0]) & 0xFF
    return bytes([0x00, 0x01, b])


# ---------------- deviceId: FatScalePairWorker.getDeviceId ----------------
def device_id(verification_code_hex6: str, mac: str) -> str:
    """Long.parseLong(hex) ^ Long.parseLong(mac-hex) formatted 12 hex chars."""
    v = int(verification_code_hex6, 16)
    m = int(mac.replace(":", "").upper(), 16)
    return format_with_zero(format(v ^ m, "X"), 12)


# ---------------- weight record: DataParseUtils.parseWeightDataForA6 ----------------
def parse_weight_record(body: bytes) -> dict:
    """body = FULL payload INCLUDING the 2-byte command header (0x4802),
    exactly as DataParseUtils.parseWeightDataForA6 receives it."""
    remain = int.from_bytes(body[2:4], "big")   # toShort BE
    flags = int.from_bytes(body[4:8], "big")    # toInt BE
    unit = flags & 3
    weight = int.from_bytes(body[8:10], "big") * 0.01  # toShort * 0.01
    r = {"remainCount": remain, "unit": unit, "weightKg": round(weight, 2)}
    i = 10
    def take(n):
        nonlocal i
        v = body[i:i + n]
        i += n
        return v
    if (flags >> 2) & 1:
        r["userId"] = body[i] & 0xFF; i += 1
    if (flags >> 3) & 1:
        r["utc"] = int.from_bytes(take(4), "big")
    if (flags >> 4) & 1:
        r["tz"] = body[i] & 0xFF; i += 1
    if (flags >> 5) & 1:
        y = int.from_bytes(take(2), "big")
        mo, d, h, mi, s = (body[i] & 0xFF, body[i+1] & 0xFF, body[i+2] & 0xFF, body[i+3] & 0xFF, body[i+4] & 0xFF)
        i += 5
        r["datetime"] = [y, mo, d, h, mi, s]
    if (flags >> 6) & 1:
        r["bmi_raw"] = int.from_bytes(take(2), "big")  # decompiled *10 quirk kept raw
    if (flags >> 7) & 1:
        r["fatRatio_raw"] = int.from_bytes(take(2), "big")
    if (flags >> 8) & 1:
        r["basalMet_raw"] = int.from_bytes(take(2), "big")
    if (flags >> 9) & 1:
        r["muscleRatio_raw"] = int.from_bytes(take(2), "big")
    if (flags >> 10) & 1:
        r["muscle_raw"] = int.from_bytes(take(2), "big")
    if (flags >> 11) & 1:
        r["fatFree_raw"] = int.from_bytes(take(2), "big")
    if (flags >> 12) & 1:
        r["softLean_raw"] = int.from_bytes(take(2), "big")
    if (flags >> 13) & 1:
        r["waterRatio_raw"] = int.from_bytes(take(2), "big")
    if (flags >> 14) & 1:
        r["impedance"] = int.from_bytes(take(2), "big")
    return r


def push_user_info(slot: int, sex_male: bool, age: int, height_m: float,
                   athlete: bool, activity: int, weight_kg) -> bytes:
    """Port of ProtocolCommand.getWeightUserInfoForA6Push (11-byte frame incl. cmd)."""
    p = to4bytes_short(0x1001)
    p += bytes([slot & 0xFF])
    p += bytes([0 if sex_male else 1])
    p += bytes([age & 0xFF])
    p += to4bytes_short(int(height_m * 100))          # height ×100, BE 2B
    p += bytes([1 if athlete else 0])
    p += bytes([activity & 0xFF])
    if weight_kg is not None and weight_kg > 0:
        p += to4bytes_short(int(weight_kg * 100))     # weight ×100, BE 2B
    else:
        p += b"\xff\xff"
    return p


# ================= golden vector generation =================
MAC = "31:06:1B:CB:0B:D8"          # captured live 2026-09-20
MAC_NOCOLON = "31061BCB0BD8"
FW_NEW = "1.5.0.0"                  # >= 1.4.0.25 -> XOR variant
FW_OLD = "1.3.0.0"                  # <  1.4.0.25 -> plain variant

vec = {}

# --- CRC32 vectors (include standard check value 0x517848B2? no: this variant inits 0,
#     so "123456789" gives a different value than zlib's 0xCBF43926; we record ours) ---
vec["crc32"] = {
    "empty": [crc32_hex(b""), "00000000"],
    "123456789": [crc32_hex(b"123456789"), None],  # filled below
    "mac_payload": [crc32_hex(mac_bytes(MAC)), None],
    "ones_18": [crc32_hex(b"\x11" * 18), None],
}
vec["crc32"]["123456789"][1] = crc32_hex(b"123456789")
vec["crc32"]["mac_payload"][1] = crc32_hex(mac_bytes(MAC))
vec["crc32"]["ones_18"][1] = crc32_hex(b"\x11" * 18)

# --- XOR vectors ---
vec["xor"] = {
    "cmd_0007_challenge": xor_key(bytes.fromhex("0007AABBCCDDEEFF0011"), mac_bytes(MAC)).hex().upper(),
    "cmd_1001_userinfo": xor_key(bytes.fromhex("10010001603c001600000000ffff"), mac_bytes(MAC)).hex().upper(),
}

# --- ACK vectors ---
vec["ack"] = {
    "ok_xored": ack_packet(True, MAC, True).hex().upper(),
    "fail_xored": ack_packet(False, MAC, True).hex().upper(),
    "ok_plain": ack_packet(True, MAC, False).hex().upper(),
}

# --- deviceId vectors (verification code = auth challenge payload[2:8]) ---
VC = "AABBCCDDEEFF"
vec["deviceId"] = {
    "code": VC,
    "mac": MAC,
    "deviceId": device_id(VC, MAC),
}
# sanity: also show the real captured scale's would-be value pattern
vec["deviceId"]["capturedMacSelfTest"] = device_id("123456", MAC)

# --- single-frame encode (register command 0x0001, 9 bytes payload, xored) ---
vec["encode"] = {}
reg_payload = bytes.fromhex("0001") + mac_bytes(MAC) + bytes([0x01])
vec["encode"]["register_cmd"] = {
    "input_hex": reg_payload.hex().upper(),
    "fw": FW_NEW,
    "frames_hex": encode_packet(reg_payload, MAC, True).hex().upper(),
}
reg_payload_plain = bytes.fromhex("0001") + mac_bytes(MAC) + bytes([0x01])
vec["encode"]["register_cmd_plain"] = {
    "input_hex": reg_payload_plain.hex().upper(),
    "fw": FW_OLD,
    "frames_hex": encode_packet(reg_payload_plain, MAC, False).hex().upper(),
}

# --- auth response 0x0008: ["01"][vc 6B][mode 1]["02"] + cmd header ---
auth_payload = bytes.fromhex("0008") + b"01" .encode()[:2] if False else bytes.fromhex("000831") + VC.encode() + bytes([0x01]) + b"02"
# NOTE: decompiled getAuthResponseForA6Command builds: cmd(2B) + "01" as HEX? -> appends the STRING "01"
# via stringBuffer, i.e. ASCII '0''1' = 0x30 0x31, then the code string as ASCII, mode as 2 hex digits, "02" as ASCII.
# Recreate exactly:
def auth_response(ok: bool, vc: str, mode: int) -> bytes:
    sb = to4bytes_short(0x0008).hex().upper()      # "0008"
    sb += "01" if ok else "02"                      # RESPONSE_SUCCESS or DEFAULT_PHONE_PLATFORM ("02")? decompiled: z ? "01" : "02"
    sb += vc                                        # verification code as-is (ASCII hex string)
    sb += format_with_zero(str(mode), 2)            # mode zero-padded to 2 chars
    sb += "02"                                      # DEFAULT_PHONE_PLATFORM
    return bytes.fromhex(sb)

auth = auth_response(True, VC, 1)
vec["encode"]["auth_response"] = {
    "input_hex": auth.hex().upper(),
    "fw": FW_NEW,
    "frames_hex": encode_packet(auth, MAC, True).hex().upper(),
}

# --- single-frame encode (push user info 0x1001 = 11 bytes incl. cmd, xored) ---
userinfo = push_user_info(slot=0, sex_male=True, age=33, height_m=1.75,
                          athlete=False, activity=0, weight_kg=None)
vec["encode"]["user_info"] = {
    "input_hex": userinfo.hex().upper(),
    "fw": FW_NEW,
    "frames_hex": encode_packet(userinfo, MAC, True).hex().upper(),
}

# --- multi-frame (force >18B payload: target 0x1003 is 6B; use clear-data 0x1005 = 10B;
#     instead craft a 24-byte synthetic setting payload to force 2 frames + CRC) ---
big = bytes(range(24))
vec["encode"]["big_24b_2frames"] = {
    "input_hex": big.hex().upper(),
    "fw": FW_NEW,
    "frames_hex": encode_packet(big, MAC, True).hex().upper(),
}

# --- decode vectors (device->app): craft 0x0007 auth challenge frame pair ---
vec["decode"] = {}
# challenge payload (post header decode): cmd 0007 + 6B code
chal = bytes.fromhex("0007") + bytes.fromhex(VC)
enc_chal = encode_packet(chal, MAC, True)
# simulate what the DEVICE sends: device XORs with MAC too (same direction obfuscation)
vec["decode"]["auth_challenge"] = {
    "wire_hex": enc_chal.hex().upper(),
    "mac": MAC,
    "fw": FW_NEW,
    "expect_command": "0007",
    "expect_payload_hex": chal.hex().upper(),
}

# --- weight record vector: flags with utc+impedance, weight 72.85kg ---
# body after cmd header: [remainCount 2B][flags 4B][weight 2B][utc 4B][impedance 2B]
body = bytearray()
body += to4bytes_short(3)                    # remainCount = 3  (2 bytes)
flags = (1 << 3) | (1 << 14) | 0             # bit3 utc, bit14 impedance, unit kg
body += to4bytes_int(flags)
body += to4bytes_short(7285)                 # weight 72.85
body += to4bytes_int(1758432000)             # utc
body += to4bytes_short(510)                  # impedance 510 ohm
record_cmd = to4bytes_short(0x4802) + bytes(body)
vec["weight_record"] = {
    "cmd_header": "4802",
    "body_hex": bytes(body).hex().upper(),
    "full_payload_hex": record_cmd.hex().upper(),
    "parsed": parse_weight_record(record_cmd),
}

with open("realme-scale-re/analysis/tools/golden_vectors.json", "w") as f:
    json.dump(vec, f, indent=2)

print(json.dumps(vec, indent=2))
