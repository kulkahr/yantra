# SRD-007 — Firmware Update (DFU) Client Support

Parent: SRD-000 · Priority P2 (only needed if realme/Lifesense ever publishes scale firmware) · Protocol source: `com.realme.iot.smartscale.ota.DfuConstanct`, `com.lifesense.ble.business.ota.DeviceUpgradeCentre`, `DataParseUtils.getUpdateModelFromUpgradeFileName`

## 1. Purpose

Recognize a scale in bootloader/DFU mode and, if the user explicitly supplies official firmware, perform an update. Firefly does **not** host or download firmware by default (privacy + supply-chain safety).

## 2. DFU facts extracted from the official app

| Item | Value |
|---|---|
| DFU-mode advertised names | `LsD…` / `LsDfu…` prefixes (`DataParseUtils.isUpgradeModelDevice`) |
| Update image model codes | `LS` = application, `SD` = SoftDevice, `BL` = bootloader (`getUpdateModelFromUpgradeFileName`) — Nordic nRF52-style DFU |
| Upgrade flow | dedicated OTA worker (`protocol/worker/ota`), progress callbacks, `DeviceUpgradeCentre` orchestration |
| Failure path | official app offers "DFU again" dialog (`DialogUtil`: `scale_device_dfu_again`) |

## 3. Requirements

| ID | Requirement |
|---|---|
| FR-1 | App SHALL detect DFU-mode broadcasts (`LsD`/`LsDfu` names) in SRD-001 scan and label them "update mode" instead of offering binding. |
| FR-2 | App SHALL, on user request, accept a user-provided firmware file and run the Nordic-style DFU sequence per the official worker (init packet, chunked transfer, progress, resume-on-failure). |
| FR-3 | App SHALL warn: interrupting power/Bluetooth mid-update can brick the scale; show progress percentage (official uses same `getProcessValue` 0–100 logic). |
| FR-4 | App SHALL NOT fetch firmware from the internet by default; if a firmware URL is user-supplied, hash + size are shown before install. |
| FR-5 | Out of scope for v1: producing/serving firmware images. |

## 4. Acceptance criteria

1. Scale placed in DFU mode appears in app as "update mode, not bindable".
2. With an official firmware file, update completes and scale re-advertises normal name after reboot.
3. Update over a flaky link resumes rather than corrupting the image (verify with forced disconnects).

## 5. Risks

- Firmware images are signed/encrypted by Lifesense; Firefly only transports them. Version compatibility checks rely on the file's model code (LS/SD/BL) vs. current FW read via `180a:2a26`.
