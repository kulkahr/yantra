# Lifesense "A6" BLE Protocol — realme Smart Scale (LS213-B)

Source: decompiled `split_realmeSmartScale.apk` → `com.lifesense.ble.*` (Lifesense SDK bundled inside realme Link v5.5.514.11421).
All values below were read directly from the decompiled classes referenced in each section.

---

## 1. Device identity & advertising

| Item | Value | Source |
|---|---|---|
| Product | Lifesense Body Fat Scale S11 (乐心体脂秤 S11) | `SmartScaleBindDevicePresenter` field `k` (JSON product config) |
| Model | `LS213-B` | same JSON (`model`) |
| Advertised local name | `realme Smart Scale` (retail) / `LS213-B1` (factory) | `bluetoothBroadcastName` in product config |
| Advertised service UUID | `0000A602-0000-1000-8000-00805f9b34fb` | `DeviceGattServiceUUID.DEVICE_A6_SERVICE_UUID` |
| Protocol family | "A6" | `ProtocolType.getProtocolTypeByServices()` |
| Broadcast name used by scanner | for A6 devices: the **MAC address without colons** (12 hex chars) | `BluetoothUtils.parseBroadcastName()` |
| Register/bound flag | byte at manufacturer-data offset `+4` (AD type 0xFF, len ≥ 11); default `1` | `BluetoothUtils.parseRegisterStatus()` |
| Manufacture ID | bytes `+2..+4` of manufacturer data | `BluetoothUtils.parseManufactureId()` |
| DFU-mode names | devices named `LsD*` / `LsDfu*` are bootloader-mode devices | `DataParseUtils.isUpgradeModelDevice()` |

Scan filter logic (`BleScanCentre.checkingScanFilter`):
- Device must advertise the Lifesense service UUID (`A602`).
- First character of the broadcast string must be `1` for pairing-broadcasts (then chars 1–5 = model code) or `0` for normal broadcasts; `BroadcastType.ALL` accepts both.
- Optional name-prefix filter list (`DeviceFilterInfo`, prefix/suffix/equals matching).

---

## 2. GATT profile

Source: `IDeviceServiceProfiles.java`, `DeviceGattServiceUUID.java`.

**Main service `A602` (proprietary):**

| UUID (16-bit) | Role |
|---|---|
| `A602` | Primary service |
| `A621` | Notify — device → app data |
| `A624` | Write — app → device data (Write With Response) |
| `A622` | Write — app → device ACK frames |
| `A625` | Notify — device → app ACK frames |
| `A641` | Read — device feature/bitmap info |
| `A640` | Read — battery voltage |

**Standard Device Information service `180a`:** `2a29` manufacturer, `2a24` model, `2a25` serial, `2a27` hw rev, `2a26` fw rev, `2a28` sw rev, `2a23` system id.

**CCCD:** standard `2902` descriptor for notifications.

Connection flow (from `BaseDeviceWorker` / `SystemBluetoothlayer`): connect GATT → discover services → enable notifications on `A621` + `A625` → read `180a` chars → read `A641` feature → run protocol state machine.

---

## 3. Frame format (transport layer)

Sources: `DeviceDataPackage.formBytes()`, `A6ProtocolParser.generateResponsePackage()`, `DataPackageA6`.

Every BLE write/notify payload is a *frame*:

```
byte 0      : (frameCount << 4) | frameSerial
              frameCount = total frames in packet (0 for ACK-only)
              frameSerial = index of this frame (0 = header frame)
byte 1      : payload length in bytes (max 18 for 20-byte ATT MTU)
bytes 2..N  : payload, XORed with the 6 bytes of the device MAC
              (no colons) when firmware version >= Security.code ("1.4.0.25")
```

- **Packet = 1..N frames.** Frames are reassembled by serial number (`A6ProtocolParser.decodePackage`).
- **Multi-frame packets** (frameCount > 1) carry a **CRC32** (poly `0xEDB88320`, init 0, xorout 0 — verified from `DataUtils.init_crc_table`) over the **plaintext** payload. On the wire the CRC is part of the obfuscated byte stream: wire = `XOR(plaintext ‖ CRC32(plaintext))`, chunked into 18-byte frames (`DeviceDataPackage.verify()` XOR-decodes the reassembled packet, then checks the trailing 4 bytes).
- **Direction asymmetry (note):** the app→device encoder (`generateResponsePackage`) computes CRC over the *XORed* payload, but every app→device command is ≤ 18 bytes (single frame), so no CRC is ever transmitted in that direction in practice. Only device→app packets (weight records etc.) are multi-frame.
- **ACK frame** (frameCount=0, serial=0): `[0x00, 0x01, status]`, status `0x01` = OK, `0x02` = FAIL. Sent on `A622` (app→device) / `A625` (device→app).
- App→device commands are written to `A624`; each command is chunked into 18-byte frames; every command is ACKed by the device before the next is sent (command queue + 3 s resend timer, `FatScalePairWorker`).
- Optional XOR obfuscation with MAC applies to both directions and is version-gated (`Security.code = "1.4.0.25"`); header bytes 0–1 are never XORed, and the first 2 payload bytes of a header frame carry the command code (see below).

---

## 4. Command codes (packet command field)

Source: `PacketProfile.java`. The first 2 payload bytes of a header frame are the 16-bit command (`DataUtils.to4Bytes((short) cmd)` big-endian in hex-string form).

| Command | Value | Direction | Meaning |
|---|---|---|---|
| `DEVICE_REGISTE_DEVIEC_ID` | `0x0001` | app→scale | Register: [cmd][deviceId 6B][registerState 1B] |
| `DEVICE_REGISTE_RESULT` | `0x0002` | scale→app | 1 = ok, 2 = fail |
| `DEVICE_A6_BIND_NOTICE` | `0x0003` | app→scale | [cmd][userNumber 1B][confirmState 1B] |
| `DEVICE_A6_BIND_RESULT` | `0x0004` | scale→app | 1 = bound, 2 = refused |
| `DEVICE_A6_UNBIND_NOTICE` | `0x0005` | app→scale | [cmd][userState 1B] |
| `DEVICE_A6_UNBIND_RESULT` | `0x0006` | scale→app | 1 = unbound, 2 = fail |
| `DEVICE_A6_RECEIVER_AUTH` | `0x0007` | scale→app | **Auth challenge**: data[2:8] = 6-byte verification code |
| `DEVICE_A6_AUTH` | `0x0008` | app→scale | Auth response: [cmd]["01"][code 6B][mode 1B: 1=bind, 2=unbind][platform "02"] |
| `DEVICE_A6_RECEIVER_INIT` | `0x0009` | scale→app | Init request (MTU/latency/timeout/UTC capability bitmap) |
| `DEVICE_A6_RESPONSE_INIT` | `0x000A` | app→scale | Init response (capability echo + MTU + UTC + timezone + timestamp) |
| `QUERY_DEVICE_CONFIG_INFO` | `0x0066` | app→scale | Query config |
| `NEW_MEASURE_DATA` | `0x00E9` | scale→app | New measurement record (g-sensor/heart-rate/step payload) |
| `DEVICE_A6_MEASURE_SETTING` | `0x4801` | app→scale | Start/stop measure: [cmd][userNumber 1B][on/off 1B] |
| `DEVICE_A6_WEIGHT_DATA` | `0x4802` | scale→app | **Weight record** (see §6) |
| `DEVICE_A6_SETTING_CALLBACK` | `0x1000` | scale→app | Setting callback |
| `PUSH_USER_INFO_TO_WEIGHT` | `0x1001` | app→scale | Push user profile (see SRD-005) |
| `PUSH_TIME_TO_WEIGHT` | `0x1002` | app→scale | Push UTC/timezone/timestamp |
| `PUSH_TARGET_TO_WEIGHT` | `0x1003` | app→scale | Push target weight ×100 |
| `PUSH_UNIT_TO_WEIGHT` | `0x1004` | app→scale | Push unit (0 kg, 1 lb, 2 st, 3 jin) |
| `PUSH_CLEAR_DATA_TO_WEIGHT` | `0x1005` | app→scale | Clear stored records [cmd][user 1B][timestamp 4B] |
| `PUSH_FORMULA_TO_WEIGHT` | `0x1006` | app→scale | Body-fat formula selection |
| `PUSH_HEART_RATE_SWITCH` | `0x1007` | app→scale | Heart-rate switch |
| `RECEIVE_USER_INFO_TO_WEIGHT` | `0x2001` | scale→app | Echo of pushed user info |
| `RECEIVE_TARGET_TO_WEIGHT` | `0x2003` | scale→app | Echo of pushed target |
| `RECEIVE_UNIT_TO_WEIGHT` | `0x2004` | scale→app | Echo of pushed unit |
| `REAL_TIME_MEASURE_DATA` | `0xFFFF` | scale→app | Raw live measurement stream flag (`MaskCode.SAVE_LOW_16_BIT`) |
| `EXCEPTION` | `0x00FF` | scale→app | Exception record |

---

## 5. Pairing / binding state machine

Source: `FatScalePairWorker.handleProtocolWorkingflow()` (full flow, ~900 lines).

```
CONNECT (GATT) → discover services
  → enable notifies (A621, A625)
  → read device info (180a), read feature (A641)
  → REQUEST_DEVICE_ID        (host supplies deviceId, see below)
  → WRITE_REGISTER           0x0001 [deviceId][state]
  ← REGISTER_RESULT          0x0002 (1=ok, 2=fail)
  ← AUTH CHALLENGE           0x0007 → verificationCode = data[4:16] hex
  → ACK + WRITE_AUTH_RESPONSE 0x0008 ["01"][code][mode 1=bind/2=unbind]["02"]
  → REQUEST_BIND_STATE       (app asks user to confirm)
  → WRITE_BIND_NOTICE        0x0003 [userNumber][confirmState]
  ← BIND_RESULT              0x0004 (1=bound)
  → WRITE_DISCONNECT         (close GATT politely)
```

**Device ID derivation** (`FatScaleWorker.getDeviceId` / `FatScalePairWorker.getDeviceId`):

```
deviceId (12 hex chars = 6 bytes) = verificationCode (6 bytes from auth challenge)
                                    XOR
                                    MAC address bytes (6 bytes, colons stripped)
```

Binding state on the scale is per-user-slot (`userNumber` 0–4 → GUEST/USER1..USER4, `BindUserState`); `PairedConfirmState` = accept/refuse. Timeouts: 180 s pair window, 2 reconnect attempts, 3 s command resend.

---

## 6. Weight record payload (`0x4802` → `WeightData_A3`)

Source: `DataParseUtils.parseWeightDataForA6()`.

After the 2-byte command header, payload is TLV-ish with a 32-bit presence field:

| Offset | Size | Field |
|---|---|---|
| 0 | 2 B | `remainCount` — records still stored on scale |
| 2 | 4 B | flags bitfield (big-endian int) |
| 6 | 2 B | **weight ×100** (kg, 2 decimals) |
| then, if flag set, in order: | | |
| | 1 B | `userId` (flag bit 2) |
| | 4 B | UTC timestamp (bit 3) |
| | 1 B | timezone (bit 4) |
| | 7 B | date-time: year(2) month day hour min sec (bit 5) |
| | 2 B | BMI (bit 6) |
| | 2 B | body-fat ratio (bit 7) |
| | 2 B | basal metabolism (bit 8) |
| | 2 B | muscle-mass ratio (bit 9) |
| | 2 B | muscle mass (bit 10) |
| | 2 B | fat-free mass (bit 11) |
| | 2 B | soft lean mass (bit 12) |
| | 2 B | body-water ratio (bit 13) |
| | 2 B | **impedance Ω** (bit 14) — required for body-fat computation |

Flags bits 0–1 = unit (0 kg, 1 lb, 2 st, 3 jin).

Value decoding conventions (`ByteDataParser`): 16-bit "float" fields are `mantissa × 10^exponent` (exponent signed, first byte); battery voltage = `raw/100 + 1.6 V`; sFloat per Bluetooth SIG.

Body-composition metrics (BMI, fat %, water, muscle, bone) are **computed on the app side** from weight + impedance + user profile (height/age/sex/athlete) — the scale reports raw impedance only; `PUSH_FORMULA 0x1006` selects the formula set.

---

## 7. Sync worker (paired, long-connection)

Source: `FatScaleWorker`, `DeviceSyncCentre`.

- Paired scale stays connected; app pushes time (`0x1002`), user info (`0x1001`), unit (`0x1004`), target (`0x1003`) after every connect.
- Real-time stream: weight values arrive continuously during measurement (`REAL_TIME_MEASURE_DATA` / `NEW_MEASURE_DATA`); final record delivered as `0x4802` with `remainCount`.
- History: `remainCount > 0` → scale pushes stored records one by one; app ACKs; optional `0x1005` clears scale memory.
- `DeviceSyncCentre` callbacks: `onReceiveWeightData_A3`, `onRealTimeDeviceMeasureDataNotify`, `onNewDeviceMeasureDataNotify`, `onDeviceConnectStateChange`, `onWeightScaleInfoUpdate`.

---

## 8. Security assessment

| Aspect | Finding |
|---|---|
| Link encryption | None — BLE link is unencrypted/unpaired at GATT level (no Just-Works bonding in flow) |
| App-layer auth | "Challenge" verification code from scale is XORed with the **public MAC address** to derive deviceId — trivially reproducible by any app in range |
| Data integrity | CRC32 only (accidental corruption, not tamper-proofing) |
| Practical impact | **Any BLE-capable device can pair, bind, and read weight data.** The protocol is fully implementable on iOS/Android/desktop without realme's cloud. Privacy risk is on the *scale* side (anyone nearby can read measurements); the privacy-friendly client app adds no new risk and removes cloud/account exposure. |
