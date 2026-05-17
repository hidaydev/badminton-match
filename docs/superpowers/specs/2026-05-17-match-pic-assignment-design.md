# Match PIC Assignment — Design Spec

**Date:** 2026-05-17

## Overview

For each group-stage match, randomly assign one person from the group as the scoring PIC (Person In Charge). The PIC must not be playing in that match. Each person is PIC at most once per group. PICs are generated automatically when groups are confirmed and stored in the tournament snapshot.

---

## Data Model

Add one optional field to `TournamentMatch` in `src/utils/tournament.ts`:

```ts
interface TournamentMatch {
  id: string
  phase: MatchPhase
  groupId?: GroupId
  pairAId: string | null
  pairBId: string | null
  scoreA: number | null
  scoreB: number | null
  picName?: string | null   // new
}
```

No other type changes. `picName` is `null` for knockout-stage matches and whenever no assignment exists.

---

## PIC Generation Algorithm

New pure function in `src/utils/tournament.ts`:

```ts
function assignGroupPics(
  pairs: TournamentPair[],
  groups: Record<GroupId, string[]>,
  matches: TournamentMatch[]
): TournamentMatch[]
```

**Per group (A/B/C/D):**

1. For each of the 4 pairs in the group, split the pair name by `" & "` to get individual names:
   - `"Hidayat & Zaid"` → `["Hidayat", "Zaid"]`
   - If no `" & "` present, treat the whole string as one person
   - Build map: `pairId → string[]`

2. Collect all names from the 4 pairs into a pool of 8, shuffle randomly (Fisher-Yates).

3. Initialise a `used: Set<string>` (empty).

4. For each of the group's 6 matches in order:
   - Derive the 4 playing names: `pairAId`'s names ∪ `pairBId`'s names
   - Walk the shuffled pool; pick the first name where: (a) not in playing names, and (b) not in `used`
   - Set `match.picName = name`, add to `used`

5. Return the updated matches (knockout matches are returned unchanged with `picName` untouched).

**Correctness:** With 8 people, 4 eligible per match, and only 6 assignments needed, the greedy walk on a shuffled list always finds a valid assignment. It cannot get stuck.

---

## When PICs Are Generated

Inside `useConfirmGroups` in `src/queries/tournament.ts`, client-side, **after** `generateGroupMatches()` and **before** `publishTournament()`:

```ts
const matchesWithPics = assignGroupPics(pairs, localGroups, generatedMatches)
await publishTournament({ ..., matches: matchesWithPics })
```

---

## Regenerate PICs

A `useRegeneratePics` mutation in `src/queries/tournament.ts`:
- Takes the current snapshot
- Calls `assignGroupPics(snapshot.pairs, snapshot.groups, snapshot.matches)`
- Publishes the updated snapshot (same endpoint as confirm groups)
- Returns the fresh snapshot via React Query cache update

Exposed in `GroupMatches` as a small "Regenerate PICs" text button in the group header row, same style as the existing "Reset groups" link (`text-xs text-slate-500 underline`). Disabled while the mutation is pending.

---

## Display

In `GroupMatches.tsx`, inside each match row, below the score badge:

```tsx
{m.picName && (
  <span className="text-[9px] text-slate-500 mt-0.5 block text-center leading-none">
    {m.picName}
  </span>
)}
```

The score badge column becomes a small flex column:

```tsx
<div className="shrink-0 min-w-[56px] flex flex-col items-center">
  <span className="text-xs font-bold text-yellow-400 bg-slate-900 rounded-md px-2 py-1">
    {m.scoreA !== null ? `${m.scoreA}–${m.scoreB}` : '—'}
  </span>
  {m.picName && (
    <span className="text-[9px] text-slate-500 mt-0.5 leading-none">{m.picName}</span>
  )}
</div>
```

---

## Files Changed

| File | Change |
|------|--------|
| `src/utils/tournament.ts` | Add `picName` to `TournamentMatch`; add `assignGroupPics()` |
| `src/queries/tournament.ts` | Call `assignGroupPics` in `useConfirmGroups`; add `useRegeneratePics` mutation; export it |
| `src/queries/index.ts` | Export `useRegeneratePics` |
| `src/components/tournament/GroupMatches.tsx` | Render `picName` below score badge; add "Regenerate PICs" button |
