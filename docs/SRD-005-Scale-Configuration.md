# SRD-005 — Scale Configuration (Time, Unit, User Profile, Target, Formula)

Parent: SRD-000 · Priority P1 · Protocol source: `ProtocolCommand.getWeight*ForA6*`, `DataParseUtils.parse*ForA6`

## 1. Purpose

Keep the scale's settings aligned with Firefly: clock, display unit, per-slot user profile (needed for body-fat math), target weight, body-fat formula set, and heart-rate switch (if the variant supports it).

## 2. Commands

| Command | Payload layout | Notes |
|---|---|---|
| `0x1002` TIME | flags(1B) + UTC(4B)? + tz(1B)? + datetime(7B: year2,month,day,hour,min,sec)? — presence bits in flags (1/2/4) | push on every connect |
| `0x1004` UNIT | unit byte: 0=kg, 1=lb, 2=st, 3=jin | scale LED unit |
| `0x1001` USER_INFO | slot(1), sex(0 male/1 female)(1), age(1), height×100(2), athlete(1), activityLevel(1), weight×100(2) | 11-byte fixed frame; weight `0xFFFF` = unset |
| `0x1003` TARGET | slot(1), enable(1), target×100(4) | |
| `0x1006` FORMULA | formula byte (`FormulaType`) | selects body-fat formula set |
| `0x1007` HEART_RATE_SWITCH | switch byte | only on HR-capable variants |
| `0x1005` CLEAR_DATA | slot(1) + timestamp(4) | see SRD-004 |
| `0x0066` QUERY_CONFIG | [type,0] | query config echo |

Scale echoes settings back via `0x2001`/`0x2003`/`0x2004` (`RECEIVE_*`) and `0x1000` setting callbacks; the official parser (`parseWeightUserInfoForA6`, `parseWeightTargetForA6`, `parseWeightUnitTypeForA6`) decodes them for verification.

## 3. Requirements

| ID | Requirement |
|---|---|
| FR-1 | App SHALL push TIME on every successful connect (records stored offline otherwise get wrong timestamps). |
| FR-2 | App SHALL manage one profile per user slot (up to 5: GUEST + USER1–4) with local profiles in Firefly mapped to slots. |
| FR-3 | App SHALL verify echoes (`0x2001`/`0x2003`/`0x2004`) and surface mismatch warnings. |
| FR-4 | App SHALL let the user pick formula set and unit; defaults: metric/kg. |
| FR-5 | App SHALL send all settings through the SRD-002 command queue (ACK + resend semantics). |
| FR-6 | App SHALL NOT require any network to configure the scale. |

## 4. Acceptance criteria

1. Change unit in Firefly → scale LED switches unit.
2. Wrong phone timezone → after connect, scale-stored records carry correct UTC.
3. Profile edit (height/age/sex) reflected in subsequent body-fat computation (SRD-006) and echoed by scale.
4. Setting a target shows progress toward target in history view.
