# SRD-007 — Firmware Update (DFU) Client Support

Parent: SRD-000 · Priority P2 · Status: **implemented (ScaleKit DFU stack + iOS screen)** · Protocol source: `FatScaleOtaWorker`, `OtaHeader`/`BinType`/`BinInfo`, `UpgradeFileProcessor`, `DeviceUpgradeCentre`, `IDeviceServiceProfiles` (decompiled)

## 1. Purpose

Recognize a scale in bootloader/DFU mode and, with a user-supplied official firmware file, perform the update. Yantra does **not** host or download firmware (privacy + supply-chain safety). Firmware **read-back from the scale is impossible** — the DFU service is write-only and the bootloader locks flash against readback; the practical "backup" is the firmware-metadata snapshot stored in the bind record plus keeping the matching official image file.

## 2. DFU facts extracted from the official app

| Item | Value |
|---|---|
| DFU-mode advertised names | `LsD…` / `LsDfu…` prefixes (`DataParseUtils.isUpgradeModelDevice`) — **the scale reboots into DFU on its own** (device-triggered); the host only scans and connects |
| DFU service | Nordic-style `1530` service: `1531` control point (write+notify), `1532` data packet, `1534` DFU version |
| Update sequence (`FatScaleOtaWorker`) | enable `1531` notify → `[0x01, binType]` START → size(LE32)+checkModel(4B)+version(4B)+CRC16(LE16) on `1532` → `[0x08,6,0]` INIT → `[0x03]` RECEIVE → 20-byte packets with flow control (pause every **6** frames until the `0x11` resume notify) → `[0x04]` VALIDATE → `[0x05]` ACTIVATE/RESET |
| Device notifications | `[0x10, op, status]` acks (op 1 start / 3 receive / 4 validate), `[0x11]` flow resume |
| Image container (`OtaHeader`) | magic(4) + version(4) + size(4) + createUtc(4) + md5(16), then 32-byte bin descriptors at offsets 32/64/96 — `BLE` (code 4), `SOC` (8), `WIFI` (9): version(4)·size(4)·flash-address(4)·crc16(4)·md5(16); content sits at its flash address, transport appends the CRC16 (LE32) and splits into 20-byte packets |
| Update source | official app asks the realme cloud (`OtaApiHelper.getLastDfu2` with mac/otaVersion/app+user info) and downloads the file — requires a realme account; Yantra uses user-supplied files only |
| Failure path | official app offers "DFU again" dialog; reconnect loop (≤4 tries, 5 s delay) between bins |

## 3. Requirements

| ID | Requirement |
|---|---|
| FR-1 | App SHALL detect DFU-mode broadcasts (`LsD`/`LsDfu` names) and connect to them when the user starts an update; in the normal scan list they SHALL be labeled "update mode" instead of bindable. **Implemented** (`ScaleCentral` scan matching + `DfuStateMachine`). |
| FR-2 | App SHALL accept a user-provided firmware file, parse the `OtaHeader` container (`DfuImage`), and run the decompiled DFU sequence (START → image info → INIT → RECEIVE → 6-frame flow-controlled streaming → VALIDATE → ACTIVATE). **Implemented.** |
| FR-3 | App SHALL warn that interrupting power/Bluetooth mid-update can brick the scale and show progress percentage. **Implemented** (`FirmwareUpdateView`: explicit acknowledgement toggle + progress bar + phase display). |
| FR-4 | App SHALL NOT fetch firmware from the internet; the parsed container summary (version, bins, sizes) is shown before install. **Implemented.** |
| FR-5 | Producing/serving firmware images is out of scope. |
| FR-6 | Firmware read-back from the scale SHALL NOT be attempted (not supported by the DFU service); the bind record SHALL keep the firmware version/DFU-version metadata as the backup trail. |

## 4. Acceptance criteria

1. Scale placed in DFU mode appears in app as "update mode, not bindable".
2. With an official firmware file, update completes and scale re-advertises normal name after reboot.
3. Update over a flaky link resumes rather than corrupting the image (verify with forced disconnects).

## 5. Risks

- Firmware images are signed/encrypted by Lifesense; Yantra only transports them. Version compatibility checks rely on the file's model code (LS/SD/BL) vs. current FW read via `180a:2a26`.
