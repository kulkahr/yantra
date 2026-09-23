# SRD-011 — Smart-Bulb Integration

Parent: SRD-000 · Priority P2 · Status: PLANNED (stub driver shipped per SRD-009 FR-6)
Driver: `BulbDriver` (`scalekit/Sources/ScaleKit/Drivers.swift`) — scanner + session skeleton, `isStub = true`

## 1. Purpose

Control smart bulbs directly from the Firefly hub over BLE with the same privacy model: no vendor cloud, no accounts, commands go phone → bulb and nowhere else.

## 2. Why a placeholder SRD (not implemented yet)

Consumer BLE bulbs concentrate into two protocol families:

| Family | Protocol shape | Examples | Notes |
|---|---|---|---|
| Telink-style direct BLE | Vendor service `0xFFF0`/`0xFFE0`, write characteristic `0xFFF1`/`0xFFE9`, notify `0xFFF2`/`0xFFEA`; commands like `AA 01 …` checksummed frames | Yeelight < v2, many white-label bulbs, Triones strips | Well-documented in community projects; reverse-engineering cost low |
| BLE mesh | Mesh profiles with provisioned node addressing | IKEA Trådfri (remote-bound), many Wiz/Mesh bulbs | Requires mesh provisioning keys — heavy for a phone-only hub |
| WiFi-first with BLE provisioning | BLE only used to hand WiFi credentials; control goes via vendor cloud | Tuya bulbs | **Rejected**: violates NFR-1 (no cloud) for control path |

**Decision gate:** SRD-011 is completed only after a physical target bulb is chosen. Step one is a capture of advertisement + GATT + a command exchange from the vendor app (same methodology as the scale), then port the frame map here.

## 3. Scope (what Firefly wants from a bulb)

| Priority | Control | Notes |
|---|---|---|
| P1 | On/off | One opcode on most Telink-style bulbs |
| P1 | Brightness | Usually `0x00–0xFF` payload byte |
| P2 | Color (RGB/HSV) | 3–5 byte payloads, vendor-specific order |
| P2 | Color temperature | White-range bulbs |
| P3 | Scenes/schedules | Vendor-heavy; only if the frame map is clean |

## 4. Requirements (pre-drafted, to be confirmed against the target device)

| ID | Requirement |
|---|---|
| FR-1 | The bulb SHALL appear in the Devices hub via `BulbDriver` scan and be controllable without any vendor account or cloud round-trip. |
| FR-2 | The driver SHALL implement the full `DeviceSession` lifecycle: connect → service discovery → (optional notify enable for state) → command writes; hub-level pairing records the bulb in `devices.json` (SRD-009 FR-4). |
| FR-3 | Bulb state (last-known on/off, brightness, color) SHALL persist locally per device and be restored into the UI; it is a cache, not a subscription — reconnect re-reads state where the protocol allows. |
| FR-4 | Commands SHALL be fire-and-write with a bounded retry (3 attempts, NFR-5 parity); no background reconnection loops (bulbs sleep aggressively). |
| FR-5 | Multiple bulbs MAY be paired (unlike the scale's single-device assumption); the hub list stays the source of truth. |

## 5. Acceptance criteria

1. Chosen bulb appears in the hub, connects, and toggles on/off + brightness from the driver page with zero cloud involvement.
2. Reconnection reuses the persisted peripheral id (`retrievePeripherals(withIdentifiers:)`) with a name/MAC-scan fallback (scale parity).
3. Frame map + golden vectors for the chosen bulb documented in this SRD.
