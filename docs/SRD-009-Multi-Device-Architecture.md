# SRD-009 — Multi-Device Architecture (Watch, Bulb, and Beyond)

Parent: SRD-000 · Priority P1 · Status: IMPLEMENTED (architecture + scale driver; watch/bulb stubs)

## 1. Purpose

Firefly started as a single-purpose smart-scale client. This SRD restructures it into a **multi-device hub**: one app, one privacy model, many device kinds — starting with the scale (fully implemented, SRD-001…007), and preparing first-class support for smart watches (health/fitness data) and smart bulbs (lighting control).

Design driver: **adding a new device kind must not touch the existing UI or stores** — it ships as a *driver* + *capability views* that plug into a registry.

## 2. Architecture

### 2.1 Layers

| Layer | Contents | Rules |
|---|---|---|
| **Protocol** (ScaleKit) | Link types (`LinkAction`/`LinkEvent`), per-device state machines, codecs | Pure Swift, no UI, no singletons, fully unit-tested |
| **Core** (iOS) | `DeviceDriver` protocol, `DriverRegistry`, `DeviceStore` (persistent device inventory), transport plumbing | Knows nothing about specific devices |
| **Feature UI** | Per-driver views (scale: Measure/History; watch: rings; bulb: controls) + shared hub | Reads only its driver's model |

### 2.2 Core abstractions (iOS, `DeviceCore/`)

```swift
/// Every connectable device kind implements this.
protocol DeviceDriver {
    var kind: DeviceKind { get }                    // .scale, .watch, .bulb …
    var displayName: String { get }                 // "Smart Scale"
    func makeScanner() -> DeviceScanner             // advertisement matching + parsing
    func makeSession(peripheral: CBPeripheral, advertisement: AdvertisementSnapshot) -> DeviceSession
}

/// Advertised device, normalized across drivers.
struct AdvertisementSnapshot {
    var peripheralId: UUID, name: String?, rssi: Int
    var manufacturerData: Data?, kind: DeviceKind
}

/// Scans for one kind of device.
protocol DeviceScanner: AnyObject {
    var onFound: ((AdvertisementSnapshot) -> Void)? { get set }
    func start(_ central: CBCentralManager); func stop()
}

/// A connected device: owns its state machine(s), publishes a SwiftUI model.
protocol DeviceSession: AnyObject {
    var model: AnyObject & ObservableObject { get }  // driver-specific published state
    func handle(centralEvent: CentralEvent)          // connected/discovered/notify/…
    func disconnect()
}
```

`CentralEvent` wraps the CBPeripheralDelegate callbacks once, centrally (one `CBCentralManager`, one delegate); every driver receives normalized events. This removes the per-device delegate boilerplate that made `ScaleCentral` monolithic.

### 2.3 Device identity & inventory

`DeviceStore` persists the user's paired devices (`devices.json`): `{ id, kind, name, driverState: [...] }` — the scale stores its bind record/MAC, a bulb its color state, etc. The **Devices hub** lists this inventory; adding a device routes to the selected driver's scanner.

### 2.4 What stays scale-specific

All SRD-001…007 behavior (pairing, sessions, history, people, calibration, DFU) is untouched behind `ScaleDriver`. The multi-person model (SRD-008) remains scale-scoped: watch/bulb devices do not participate in user-slot attribution.

## 3. Device kinds

### 3.1 Smart Scale — `ScaleDriver` (complete)

Full SRD-001…007/SRD-008 behavior. Tabs: Measure · History · Device (existing views, re-homed under the hub).

### 3.2 Smart Watch — `WatchDriver` (stub → SRD-010)

**Not yet protocol-specified.** Watches vary wildly (BLE GATT services: standard BPS/HRS + vendor clocks). The stub ships: scanner matching vendor prefixes, session skeleton, and a placeholder view, so the *app structure* is final while protocol work lands in **SRD-010 (Watch Integration — to be written when a target watch is chosen)**.

### 3.3 Smart Bulb — `BulbDriver` (stub → SRD-011)

Consumer bulbs are mostly BLE mesh or vendor-private (Telink-style `0xFFF0`/`0xFFE0` services, or WiFi+cloud). The stub ships the same skeleton; protocol specifics land in **SRD-011 (Bulb Integration — to be written when a target bulb is chosen)**. Control model (on/off, brightness, color) is driver-local state; no Firefly-side cloud.

## 4. Requirements

| ID | Requirement |
|---|---|
| FR-1 | App SHALL present a **Devices hub** as the home screen listing paired devices grouped by kind, with an add-device flow choosing the kind first. |
| FR-2 | Device kinds SHALL be provided exclusively by `DeviceDriver` implementations registered in `DriverRegistry`; core/UI code SHALL NOT switch on device kind outside the registry. |
| FR-3 | Each driver SHALL own its scanner, session and SwiftUI model; the shared BLE transport SHALL be reused (single `CBCentralManager`). |
| FR-4 | The device inventory (`DeviceStore`) SHALL persist across launches and restore each device's driver state (bind record, name, …). |
| FR-5 | The scale driver SHALL preserve 100% of existing SRD-001…008 behavior after restructure (regression: existing tests keep passing). |
| FR-6 | Watch/bulb drivers MAY ship as documented stubs (scanner skeleton + placeholder UI) until their protocol SRDs exist; the hub SHALL mark them "coming soon" honestly. |
| FR-7 | NFR-1 privacy applies to every driver: no cloud, no accounts, telemetry-free, data local by default. |

## 5. Acceptance criteria

1. App launches into the Devices hub; the paired scale opens Measure/History/Device unchanged.
2. Adding a device → pick kind → driver-specific scan → pair → appears in hub.
3. `swift test` ScaleKit and FireflyTests all green after restructure.
4. A new driver can be added by implementing `DeviceDriver` + registering it, with zero edits to hub code (registry-driven).
