# realme Link App — Architecture & Privacy Analysis

App: `com.realme.link` v5.5.514.11421 (versionCode 530121), minSdk 26, targetSdk 35.
Decompiled with jadx: `decompiled/base` (22,326 classes) + `decompiled/smartscale` (950 classes).

## 1. Modular architecture (Android App Bundle)

The app is a monolith shell + **on-demand dynamic feature modules**, one per device family:

| Split | Purpose |
|---|---|
| `base.apk` | Shell: home, account (`id.realme.com`), device list, scenes, health dashboard, push, statistics |
| `split_realmeSmartScale.apk` | **The scale: complete Lifesense BLE SDK + scale UI/bind flow** |
| `split_realmeBracelet.apk` | realme Band support |
| `split_realmeHeadset.apk` | Earbuds support |
| `split_realmeLinkStore.apk` | In-app device store |
| `split_vendorIdoBand.apk`, `split_vendorLifesenseWatch.apk`, `split_vendorRyeexWatch.apk`, `split_vendorTouchGWatch.apk` | Third-party OEM vendor stacks (note: *another* Lifesense module for watches) |

## 2. Scale data flow (end to end)

```
realme Smart Scale (LS213-B)
   │ BLE: service A602, A6 protocol (see PROTOCOL_ANALYSIS.md)
   ▼
com.lifesense.ble.*            — Lifesense SDK (scan/pair/sync workers, GATT layer)
   ▼
com.lifesense.component.devicemanager  — "LZ" device-manager SDK
   │   LzDeviceService, LXDeviceManager, UserManager, WeightDataManager
   │   local Room DB: WeightDbData (weight, deviceId, utc...)
   ▼
com.realme.iot.smartscale.*    — realme UI glue (26 classes)
   │   SmartScaleDeviceManager, SmartScaleBindDevicePresenter, Home/Bind activities
   ▼
┌─────────────────────────────┬──────────────────────────────────────┐
│ Local consumption           │ Cloud upload (optional, gated)       │
│ - weight list UI            │ - DeviceApiHelper → realme IoT API   │
│ - Health card "bodyfat_     │   (upload==1 flag on DeviceDomain)   │
│   scale" dashboard          │ - Lifesense cloud (DeviceNetManager) │
│ - JS bridge (WeightJS-      │   for device registry / config sync  │
│   Handler → webview charts) │ - account: id.realme.com login       │
└─────────────────────────────┴──────────────────────────────────────┘
```

Key observations:

- Binding requires a **realme account login** (`SmartScaleBindDevicePresenter` → `LxLogin` → `LZDeviceService.LSLoginListener`) before `searchDevice`/`bindDeviceBySearchResult` are invoked — the *SDK* itself does not need it, only realme's cloud device-registry does.
- After bind, the app uploads the device record (`uploadServer`, `DeviceApiHelper.d(...)`) and sets `deviceDomain.setUpload(1)`.
- Measurement data lands in a local DB first (`WeightDataDbManager`) and is then surfaced/synced per app logic — i.e. **the scale → app path never touches the cloud**; cloud is an opt-in downstream step. A standalone client can stop after the BLE layer with zero realme infrastructure.
- The scale product config is fetched/evaluated from a JSON descriptor embedded in `SmartScaleBindDevicePresenter.k`, which is where the `LS213-B` identity and the two broadcast names (`LS213-B1`, `realme Smart Scale`) are declared.

## 3. Permissions requested by the scale module

`BLUETOOTH`, `BLUETOOTH_ADMIN`, `ACCESS_FINE_LOCATION` (scan), `ACCESS_COARSE_LOCATION`, `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_NETWORK_STATE`, `CAMERA` (QR bind), `VIBRATE`, `READ/WRITE_EXTERNAL_STORAGE`.

A minimal client needs only: **BLUETOOTH_SCAN, BLUETOOTH_CONNECT (Android 12+), ACCESS_FINE_LOCATION (Android ≤11)**.

## 4. Privacy findings

1. **Account-required onboarding** — realme Link cannot bind the scale without a realme cloud account; the device-registry API associates the scale's MAC/serial with the user's identity.
2. **Telemetry SDKs** — `BleReportCentre`/`BleReportCentre` log action events (scan results, pair results, disconnects) and `com.realme.iot.statistics` + `ServerDataUploader` ship diagnostics out of the app.
3. **No on-the-wire encryption** — see protocol security assessment; the scale broadcasts presence and (via manufacturer data) registration state to anyone scanning.
4. **Implication for Firefly** — a local-only client (no account, no cloud, local DB or Apple Health export) strictly *reduces* the data exposure compared to the official app.

## 5. Reusable building blocks for the Firefly app

- Scan: filter on advertised service `0xA602`; read local name `realme Smart Scale`; read registration-state byte from manufacturer data.
- Connect & negotiate: A602 characteristics (`A621/A624/A622/A625/A641/A640`, `180a`).
- Pair/bind handshake, auth challenge → deviceId derivation (`verificationCode XOR MAC`).
- Weight record parser (`0x4802` layout incl. impedance), real-time stream handling, history drain via `remainCount`.
- Config pushes: time, unit, user profile, target, formula.
