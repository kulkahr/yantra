# SRD-008 — Multi-Person Weight Assignment

Parent: SRD-000 · Priority P1 · Related: SRD-003 (realtime), SRD-004 (history), SRD-006 (composition)

## 1. Purpose

Several people share one physical scale. Yantra must (a) attribute live weigh-ins to the correct person, (b) never silently mis-attribute weigh-ins that happened while nobody was connected, and (c) let the user correct attribution later. The scale's `0x4802` record carries a `userId` byte whose slot semantics are **unverified** on the LS213-B firmware, so attribution is app-driven.

## 2. Model

- `Person` = { id, name, slot (1…5), sex, age, height, target weight, createdAt }. The 5-slot limit is the scale hardware's max-user-number (feature bitmap, SRD-006); one person owns one slot, freed on removal.
- `MeasurementRecord.personId` — owner of the record; `nil` = **unassigned** (awaiting user choice). Unassigned records are never summed into per-person stats.
- `PersonStore` — persisted (`people.json`), synchronous in-memory state with synchronous disk writes (writes are tiny; avoids the read-after-write race found in testing).

## 3. Attribution rules

| Weigh-in happens… | Attribution |
|---|---|
| During a session with an **active person** set, timestamp ≤ 10 min old | Active person, automatically. |
| Drained from scale memory (offline weigh-in — could have been anyone) | **Unassigned** — History asks, per record. |
| No active person at session start | Unassigned — History asks, per record. |

**Freshness window = 10 min** (weigh-in duration ≤ a few minutes + device clock drift). A record whose UTC is in the future by > 60 s is treated as drained (scale clock skew).

The active person is chosen on the Device tab ("Set active"); the Measure tab shows *"Weighing as X (slot N)"* so the user knows who is on the scale.

## 4. Assignment flow (History)

1. Orange banner: *“N unassigned weight(s) — tap to assign”* when unassigned records exist.
2. The assignment sheet lists each unassigned record (weight + timestamp) with a person picker: **choose a person** or **skip**. Skip = leave unassigned, no nag loop.
3. Bulk helpers: "All → person", cycle-through-people for rapid triage, inline person creation from the sheet.
4. Any row can be re-assigned at any time via a chip/button on the row.
5. History **follows the active person** by default (scope: follow-active / all / pinned person); the trend chart colors points by person.

## 5. Composition profiles

Body composition (SRD-006) uses the **weighing person's** profile (sex/age/height stored per person, issue #3) rather than a single global profile; the default profile is the fallback for unassigned records.

## 6. Requirements

| ID | Requirement |
|---|---|
| FR-1 | App SHALL support ≥ 2 people, each claiming a distinct scale slot (1…5). |
| FR-2 | Live records SHALL be attributed to the active person only when the record UTC is ≤ 10 min old; older records remain unassigned. |
| FR-2a | Drained-memory records SHALL stay unassigned until the user assigns them. |
| FR-3 | App SHALL surface unassigned records prominently and provide a per-record assignment flow with skip. |
| FR-4 | App SHALL allow re-assignment of any record at any time. |
| FR-5 | History SHALL default to following the active person, with all-records and per-person scopes. |
| FR-6 | App SHALL keep records attributed correctly when people are removed (records keep personId; display falls back to "Unknown"). |
| FR-6a | Composition SHALL use the record owner's profile when the record is assigned. |
| FR-7 | CSV export SHALL include the person name column. |

## 7. Acceptance criteria

1. Two people alternate stepping on the scale with active-person switching in between → each record attributed to the person active at weigh-in time.
2. Weigh while Yantra is closed, then drain → record appears unassigned, History asks, assignment sticks across restarts.
3. Removing a person keeps their historical records viewable (shown as "Unknown") and frees the slot for a new person.
4. CSV opened in a spreadsheet shows a person column matching the UI.
