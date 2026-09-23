# SRD-006 — Device Info, Battery & Body-Composition Computation

Parent: SRD-000 · Priority P1 · Protocol source: `IDeviceServiceProfiles.DeviceInfoUUID`, `DataParseUtils.parseWeightScaleVoltage`, `BluetoothUtils.getDeviceFeature`, `ByteDataParser`

## 1. Purpose

Expose scale identity, battery state, feature bitmap; compute body-composition metrics from raw measurements (the scale sends raw weight + impedance; the official app computes BMI, body-fat, water, muscle, bone, visceral level, basal metabolism client-side).

## 2. Device information (standard service `180a`)

| Characteristic | Content |
|---|---|
| `2a29` | Manufacturer name (Lifesense) |
| `2a24` | Model (`LS213-B`) |
| `2a25` | Serial number |
| `2a27` / `2a26` / `2a28` | HW / FW / SW revisions — FW version also gates the XOR-obfuscation variant ("1.4.0.25") |
| `2a23` | System ID |

**A6-specific reads:**
- `A641` — device **feature bitmap** (`DeviceFeature`: capabilities, bind-state bits `isBind()`/`isUnbind()`, max-user-number).
- `A640` — **battery voltage** byte: `V = raw/100 + 1.6 V` (LiSOCl2-style curve; map to % with S11 discharge curve, low-battery < 2.8 V).

## 3. Body-composition computation

Inputs per measurement: weight (kg, ×100 from `0x4802`), impedance Ω (raw, when bit 14 set), user profile (sex, age, height, athlete flag + activity level).

Outputs (computed client-side, clearly separated from raw values in UI per NFR-2):

| Metric | Notes |
|---|---|
| BMI | weight / height² |
| Body-fat % | impedance-based formula (S11 formula set selectable via `0x1006`) |
| Water %, muscle mass, fat-free mass, soft-lean mass | derived per formula set |
| Basal metabolism | derived (kcal) |
| Visceral fat level, bone mass | derived where supported by formula set |

Official app displays: weight, BMI, body-fat ratio, basal metabolism, muscle mass (+ratio), fat-free mass, soft lean mass, body-water ratio, bone density, visceral-fat level — all derived from the same raw pair (weight, impedance) + profile (verified in `WeightData_A3` bean and JS-bridge chart handlers).

## 4. Requirements

| ID | Requirement |
|---|---|
| FR-1 | App SHALL read and display manufacturer, model, serial, HW/FW/SW revisions on the device page. |
| FR-2 | App SHALL read `A641` at bind and store the feature bitmap; gate UI features (e.g., HR switch) on it. |
| FR-3 | App SHALL read `A640` on connect and at measurement end; show battery % with low-battery warning. |
| FR-4 | App SHALL compute body-composition only when impedance is present; otherwise show weight-only and say why. |
| FR-5 | App SHALL show raw (weight, impedance) and computed values distinctly; export both. |
| FR-6 | Computed values SHALL match official realme Link within display tolerance (±0.1 % body-fat, ±1 kcal BMR). **Derivation (verified in the decompiled APK):** the official app uploads only weight + impedance to `weight_service/weight/syncToServer` and displays cloud-composed values — no local formulas exist to port. FR-6 is therefore met via `BodyCalibration`: a capture screen stores paired samples (raw weigh-in + official-app values), a least-squares refit replaces the fat % impedance model (`fat% = c0 + c1·h²/R + c2·W + c3·age`, zero-variance columns dropped) and affine-corrects other metrics; ≥ 4 samples, same person + profile. |

## 5. Acceptance criteria

1. Device page shows all `180a` fields for the physical scale.
2. Battery % decreases monotonically with scale usage and low-battery state matches scale's own low-battery indicator.
3. Same user + same measurement in Firefly and realme Link → same BMI/fat% (±0.1).
4. Weight-only measurement (shoes on) → no fabricated body-fat values.
