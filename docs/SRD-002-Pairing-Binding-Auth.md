# SRD-002 — Pairing, Binding & Authentication

Parent: SRD-000 · Priority P0 · Protocol source: `FatScalePairWorker`, `ProtocolCommand`, `A6ProtocolParser`, `DeviceDataPackage`

## 1. Purpose

Establish a trust relationship between Yantra and the scale: register a device ID, answer the scale's auth challenge, claim a user slot, and persist the bind record for future sessions.

## 2. GATT resources used

| UUID | Use |
|---|---|
| `A602` | service |
| `A621` (notify) | device → app frames |
| `A624` (write) | app → device command frames |
| `A622` (write) | app → device ACKs |
| `A625` (notify) | device → app ACKs |
| `A641` (read) | device feature bitmap |
| `180a` chars | device info (SRD-006) |

## 3. State machine (port of official worker)

```
CONNECT_GATT → SERVICES_DISCOVERED
  → ENABLE_NOTIFIES(A621, A625)
  → READ_DEVICE_INFO(180a) → READ_FEATURE(A641)
  → REQUEST_DEVICE_ID
  → WRITE_REGISTER      0x0001 [deviceId(6B)][registerState(1B)]
  ← REGISTER_RESULT     0x0002  (1 ok / 2 fail)
  ← AUTH_CHALLENGE      0x0007  → verificationCode = payload[4:16] hex
  → ACK(ok) + WRITE_AUTH_RESPONSE 0x0008 ["01"][code(6B)][mode(1B)][platform "02"]
        mode: 0x01 = bind, 0x02 = unbind
  → REQUEST_BIND_STATE            (UI confirm step)
  → WRITE_BIND_NOTICE   0x0003 [userNumber(1B)][confirmState(1B)]
  ← BIND_RESULT         0x0004  (1 bound / 2 refused)
  → WRITE_DISCONNECT (close GATT)
```

### 3.1 Device ID derivation (must match official exactly)

```
deviceId (6 bytes, printed as 12 hex chars) =
    verificationCode (6 bytes from 0x0007 payload[4:16])
  ⊕ MAC address bytes (6 bytes, colons stripped)
```

### 3.2 Frame codec (transport)

- Frame header 2 bytes: `[frameCount<<4 | frameSerial][payloadLen]`; payload max 18 B.
- Payloads XORed with device MAC bytes when firmware ≥ "1.4.0.25" (both variants supported; header never XORed; first 2 bytes of header frame carry the command and are sent raw).
- Multi-frame packets carry trailing CRC32 (4 B) computed over reassembled payload; verify on receipt, ACK `ok`/`fail` accordingly (`[0x00,0x01,status]`).
- Commands are queued; each waits for device ACK (`A625`/`A621` ACK frame) before next; resend after 3 s; pair window 180 s; 2 reconnect attempts.

## 4. Requirements

| ID | Requirement |
|---|---|
| FR-1 | App SHALL implement the full state machine above with the official command encodings (see PROTOCOL_ANALYSIS §4–5). |
| FR-2 | App SHALL let the user choose the user slot (GUEST/USER1–4, default GUEST for first bind) and confirm bind intent in UI before `WRITE_BIND_NOTICE`. |
| FR-3 | App SHALL support unbind (`mode=0x02`, `0x0005` notice with `BindUserState.GUEST`) to release slots. |
| FR-4 | App SHALL persist bind record: `deviceId`, MAC/identifier, slot, firmware version, feature bitmap, bind date. |
| FR-5 | App SHALL verify CRC on every multi-frame packet and request retransmission via ACK-fail on mismatch. |
| FR-6 | Timeouts/resends SHALL match official constants (180 s pair, 3 s resend, 2 reconnects). |
| FR-7 | If `REGISTER_RESULT = 2` (scale already bound to another host slot), app SHALL surface guidance (scale holds 5 slots; advise freeing one via unbind). |
| FR-8 | Bind SHALL complete fully offline; no account, no network. |

## 5. Data model

```
BindRecord {
  deviceId: String          // 12 hex chars
  macOrIdentifier: String
  userSlot: Int             // 0..4
  firmwareVersion: String
  featureBitmap: Data?      // A641 read
  boundAt: Date
}
```

## 6. Acceptance criteria

1. Fresh scale → bind succeeds end-to-end in < 30 s without touching realme Link.
2. Scale bound in official app first → Yantra can bind an alternate slot or unbind the official one explicitly.
3. Killing the app mid-pair leaves the scale usable (timeouts fire, GATT closed cleanly).
4. CRC-corrupted notify frames are ACK-failed and retransmitted.
