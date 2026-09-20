# iOS Compatibility Research — realme Smart Scale on iPhone

Question: *the scale currently only connects to the Android phone (realme Link), not the iPhone. Can it be fixed?*

## 1. Current state (verified)

| Evidence | Finding |
|---|---|
| App Store listing (id1536584786, v5.8.6) | realme Link **exists for iOS** (439.7 MB) |
| App Store "warm reminder" | "Only some devices are currently supported, if your device is not in the add device list, this application is not currently supported." |
| App Store user reviews | "The app crashes or closes when adding a Realme Smart Scale device" (07/02/2023) |
| realme community/support answers | iOS app is for smart-home + wearables; scale module not ported |
| This repo's APK set | Scale support ships as an Android-only dynamic feature module (`split_realmeSmartScale.apk`); the iOS app is a separate codebase with no equivalent module |

**Conclusion: the scale is Android-only by software, not by hardware.** The scale is a standard BLE peripheral (GATT service `A602`); nothing in the decompiled protocol requires Android. realme simply never shipped the Lifesense scale stack in the iOS build.

## 2. Why it doesn't work today

1. The iOS realme Link app does not include the A6-protocol scale module (confirmed by App Store device-support list + reviews).
2. The scale does not implement any standard profile iOS natively understands:
   - Not a **Weight Scale Profile** (WSP 0x181D) — no standard `Weight Measurement` characteristic.
   - Not **Apple Health / HealthKit-compatible** out of the box (no standard GATT Health Thermometer/Weight services).
3. Therefore iOS Bluetooth settings won't pair it, and no stock iOS app can read it.

## 3. Can it be fixed? — Yes, three viable paths

### Path A (recommended): build the iOS client ourselves — this is the Firefly app
The protocol is fully documented in `analysis/PROTOCOL_ANALYSIS.md`. On iOS:
- `CoreBluetooth` central manager: scan for service `A602`, connect, discover `A621/A622/A624/A625/A641/A640` + `180a`.
- Implement the frame codec (XOR-MAC obfuscation, CRC32, 18-byte chunking), pairing state machine, `0x4802` weight-record parser — all straightforward byte work, no privileged APIs needed.
- Permissions: `NSBluetoothAlwaysUsageDescription` only. **App Store-compatible** — no `bluetooth-peripheral` background mode needed for foreground weigh-ins.
- Everything runs locally; HealthKit export is opt-in.

### Path B: third-party apps that already speak Lifesense/A6
Lifesense's protocol is used by several OEM scales; open-source projects (e.g. openScale-style BLE drivers for Lifesense scales) and some importers may already parse `0x4802`-style records. Worth testing before writing code — but verification against our decompiled spec is required since realme's variant names/broadcast differ.

### Path C: Android bridge
Keep an Android device (or the existing S23 FE) running as a bridge that relays weight data to iOS (e.g. via network/WebSocket → Shortcuts → Health). Works today, but adds a device dependency; Path A supersedes it.

## 4. Risks / caveats for Path A

| Risk | Mitigation |
|---|---|
| Firmware variance (Security.code "1.4.0.25" gate, older units without XOR) | Feature-detect via firmware version read from `180a:2a26`; support both variants (the decompiled code shows exactly how) |
| Pairing state machine timeouts (180 s pair window, 2 reconnects) | Port the same constants; test with the physical scale |
| Body-fat formula is app-side | Port the formula from SRD-006; verify against realme Link readings |
| Scale can hold one binding per user slot (0–4) | Firefly uses its own slot; unbind other slots via `0x0005` if needed |
| MFi not required | CoreBluetooth is free to use for this — no Apple approval friction |

## 5. Bottom line

- **Nothing about the scale blocks iOS.** It's a plain BLE peripheral with a proprietary-but-decoded GATT service.
- The official iOS app never got the scale module; waiting for realme to "fix" it is not a realistic plan (the gap has existed since 2021 per reviews).
- The Firefly iOS app can implement the documented protocol directly with CoreBluetooth and read weight (and body-composition raw data) with **no account, no cloud, and no Android dependency**.
