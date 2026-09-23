# SRD-001 — Device Discovery & Scan

Parent: SRD-000 · Priority P0 · Platform: iOS CoreBluetooth / Android BLE
Protocol source: `BleScanCentre`, `BluetoothUtils`, `DeviceFilterInfo`, `SmartScaleBindDevicePresenter`

## 1. Purpose

Discover nearby realme Smart Scales (Lifesense LS213-B) advertising the proprietary Lifesense "A6" service and expose them to the user for binding (SRD-002) or automatic reconnection (SRD-003/004).

## 2. Scale advertisement characteristics

| Property | Value |
|---|---|
| Advertised service UUID | `0000A602-0000-1000-8000-00805f9b34fb` |
| Local name (retail unit) | `realme Smart Scale` |
| Local name (factory/alt) | `LS213-B1` |
| DFU-mode name pattern | `LsD…` / `LsDfu…` (see SRD-007) |
| Broadcast string used by official scanner | MAC without colons (A6 devices); first hex char `1` = pairing broadcast, `0` = normal |
| Manufacturer data (AD 0xFF, len ≥ 11) | contains manufacture ID (offset +2..+4) and registration-state byte (offset +4; default 1) |

## 3. Requirements

| ID | Requirement |
|---|---|
| FR-1 | App SHALL scan filtered on advertised service `A602` (reduces battery + scan-rate throttling on both platforms). |
| FR-2 | App SHALL display: local name, MAC (iOS: peripheral identifier), RSSI, registration state (bound/unbound) when decodable. |
| FR-3 | App SHALL classify a found peripheral as *pairing-mode broadcast* vs *normal broadcast* when the first-char convention is observable, and surface "ready to pair" state. |
| FR-4 | App SHALL ignore peripherals whose name matches `LsD`/`LsDfu` prefixes in the normal device list and route them to the DFU flow (SRD-007). |
| FR-5 | Scan SHALL be stoppable and auto-time-out (official behavior: continuous scan with duty cycling; app uses 30 s foreground scan window, cancellable). |
| FR-6 | On Android ≤ 11 the app SHALL request `ACCESS_FINE_LOCATION` before scanning; on Android 12+ `BLUETOOTH_SCAN` (neverScanForLocation=false) + `BLUETOOTH_CONNECT`; on iOS `NSBluetoothAlwaysUsageDescription`. |
| FR-7 | App SHALL deduplicate results per MAC/identifier and keep the strongest RSSI sample. |
| FR-8 | App SHALL operate without Google Play Services (privacy: no nearby-API dependency). |

## 4. Data produced

```
DiscoveredScale {
  macOrIdentifier: String   // iOS CBPeripheral.identifier / Android MAC
  localName: String?        // "realme Smart Scale" | "LS213-B1" | ...
  rssi: Int
  advertisedServices: [UUID]      // expected: [A602]
  registrationState: Int?         // from manufacturer data if present
  isInPairingBroadcast: Bool?
}
```

## 5. Acceptance criteria

1. With scale awake (step-on or stable idle advertising), scan finds it within 10 s.
2. Device appears exactly once; RSSI updates live.
3. Airplane-mode/BT-off surfaces a friendly state, not a crash (official iOS app crashes here per reviews).
4. No scan happens before permission grant; denial shows explanation screen.

## 6. Notes

- iOS cannot read raw MAC; use `CBPeripheral.identifier` and persist it. Bind record must therefore store both identifier and (from GATT `180a:2a25` serial / deviceId) a stable cross-platform key.
- The official filter also matches MAC-prefix conventions (`0`/`1` first nibble); Yantra treats the service-UUID filter + name check as sufficient and more robust.
