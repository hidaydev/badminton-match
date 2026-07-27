// src/utils/tally.ts
// Shared match tallying logic — used by both session standings and tournament standings.

/** Minimal row interface for tallying wins/losses/points. */
export interface TallyRow {
  wins: number
  losses: number
  pointsFor: number
  pointsAgainst: number
  diff: number
}

/** Initialize a tally row with zero values. */
export function initTallyRow(): TallyRow {
  return { wins: 0, losses: 0, pointsFor: 0, pointsAgainst: 0, diff: 0 }
}

/** Record a match result for one entity. */
export function tallyMatch(
  row: TallyRow,
  scoreFor: number,
  scoreAgainst: number,
) {
  if (scoreFor > scoreAgainst) row.wins++
  else row.losses++
  row.pointsFor += scoreFor
  row.pointsAgainst += scoreAgainst
}

/** Compute diff for a row (call after all matches are tallied). */
export function computeDiff(row: TallyRow): void {
  row.diff = row.pointsFor - row.pointsAgainst
}

/** Standard sort: wins → diff → pointsFor. Returns comparator for Array.sort. */
export function standardStandingSort<T extends TallyRow>(a: T, b: T): number {
  if (b.wins !== a.wins) return b.wins - a.wins
  if (b.diff !== a.diff) return b.diff - a.diff
  if (b.pointsFor !== a.pointsFor) return b.pointsFor - a.pointsFor
  return 0
}
