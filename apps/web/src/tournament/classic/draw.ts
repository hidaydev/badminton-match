// Browser mirror of `modules/tournament/domain/classic_draw.nim`.
//
// Every function below is a direct port of the domain module: group draws,
// round robin, bracket propagation and standings must produce the same rows the
// server validates, or a saved snapshot is rejected with `bracket_progression`
// / `tied_match` issues. Nothing here talks to the API.

import type {
  ClassicMatch,
  ClassicPhase,
  ClassicSnapshot,
  GroupId,
  Pair,
} from '../types'

export const GROUP_IDS: readonly GroupId[] = ['A', 'B', 'C', 'D']
export const PAIR_COUNT = 16
export const GROUP_SIZE = 4
export const MAX_SCORE = 99

export const QF_IDS = ['qf-1', 'qf-2', 'qf-3', 'qf-4'] as const
export const SF_IDS = ['sf-1', 'sf-2'] as const
export const THIRD_PLACE_ID = '3rd-1'
export const FINAL_ID = 'final-1'

/** v1 round-robin over the four group slots; the order fixes the match ids. */
export const ROUND_ROBIN: readonly (readonly [number, number])[] = [
  [0, 1],
  [2, 3],
  [0, 2],
  [1, 3],
  [0, 3],
  [1, 2],
]

export type ClassicStanding = {
  pairId: string
  wins: number
  losses: number
  pointsFor: number
  pointsAgainst: number
  diff: number
}

/** Group match ids are positional: group-A-0 … group-D-5. */
export function groupMatchId(groupId: GroupId, index: number): string {
  return `group-${groupId}-${index}`
}

/**
 * v1 `getMatchWinner` only reads a match when both scores and both pair
 * references are present.
 */
export function matchDecided(match: ClassicMatch): boolean {
  return (
    match.scoreA !== null &&
    match.scoreB !== null &&
    match.pairAId !== null &&
    match.pairAId.trim() !== '' &&
    match.pairBId !== null &&
    match.pairBId.trim() !== ''
  )
}

/** Anything that is not an A win resolves in favour of B, exactly like v1. */
export function matchWinner(match: ClassicMatch): string | null {
  if (!matchDecided(match)) return null
  return match.scoreA! > match.scoreB! ? match.pairAId : match.pairBId
}

export function matchLoser(match: ClassicMatch): string | null {
  if (!matchDecided(match)) return null
  return match.scoreA! < match.scoreB! ? match.pairAId : match.pairBId
}

/**
 * A 32-bit Mersenne-like generator is not needed: only reproducibility matters.
 * mulberry32 is small, has no state outside the closure and is stable across
 * browsers, which is what the explicit draw seed relies on.
 */
function seededRandom(seed: number): () => number {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let value = state
    value = Math.imul(value ^ (value >>> 15), value | 1)
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61)
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296
  }
}

function shuffle<T>(items: T[], seed: number): T[] {
  const random = seededRandom(seed)
  for (let index = items.length - 1; index > 0; index -= 1) {
    const swapIndex = Math.floor(random() * (index + 1))
    const held = items[index]
    items[index] = items[swapIndex]
    items[swapIndex] = held
  }
  return items
}

/**
 * v1 `drawGroups`: shuffle the 16 pair ids, then cut the result into four
 * consecutive chunks of four. The seed is explicit so the same pairs always
 * land in the same groups.
 */
export function drawGroups(
  pairIds: readonly string[],
  seed: number,
): Record<GroupId, string[]> {
  if (pairIds.length !== PAIR_COUNT) {
    throw new Error('a classic draw needs exactly 16 pairs')
  }
  const shuffled = shuffle([...pairIds], seed)
  const groups: Record<GroupId, string[]> = { A: [], B: [], C: [], D: [] }
  shuffled.forEach((pairId, index) => {
    groups[GROUP_IDS[Math.floor(index / GROUP_SIZE)]].push(pairId)
  })
  return groups
}

/** The six-match round robin for one group, ids fixed by slot order. */
export function generateGroupMatches(
  groupId: GroupId,
  pairIds: readonly string[],
): ClassicMatch[] {
  if (pairIds.length !== GROUP_SIZE) {
    throw new Error('a classic group needs exactly 4 pairs')
  }
  return ROUND_ROBIN.map(([slotA, slotB], index) => ({
    id: groupMatchId(groupId, index),
    phase: 'group' as const,
    groupId,
    pairAId: pairIds[slotA],
    pairBId: pairIds[slotB],
    scoreA: null,
    scoreB: null,
  }))
}

/** The eight knockout slots with no pair references and no scores yet. */
export function initKnockoutMatches(): ClassicMatch[] {
  const slots: { id: string; phase: ClassicPhase }[] = [
    ...QF_IDS.map((id) => ({ id, phase: 'qf' as const })),
    ...SF_IDS.map((id) => ({ id, phase: 'sf' as const })),
    { id: THIRD_PLACE_ID, phase: '3rd' },
    { id: FINAL_ID, phase: 'final' },
  ]
  return slots.map(({ id, phase }) => ({
    id,
    phase,
    groupId: null,
    pairAId: null,
    pairBId: null,
    scoreA: null,
    scoreB: null,
  }))
}

function tallyMatch(row: ClassicStanding, scoreFor: number, scoreAgainst: number): void {
  if (scoreFor > scoreAgainst) row.wins += 1
  else row.losses += 1
  row.pointsFor += scoreFor
  row.pointsAgainst += scoreAgainst
}

function compareRows(a: ClassicStanding, b: ClassicStanding): number {
  if (a.wins !== b.wins) return b.wins - a.wins
  if (a.diff !== b.diff) return b.diff - a.diff
  return b.pointsFor - a.pointsFor
}

/** v1 walks the group matches in order and uses the first meeting. */
function headToHead(
  a: ClassicStanding,
  b: ClassicStanding,
  groupMatches: readonly ClassicMatch[],
): number {
  for (const match of groupMatches) {
    if (match.pairAId === null || match.pairBId === null) continue
    const pairA = match.pairAId
    const pairB = match.pairBId
    const between =
      (pairA === a.pairId && pairB === b.pairId) ||
      (pairA === b.pairId && pairB === a.pairId)
    if (!between) continue
    if (match.scoreA === null || match.scoreB === null) return 0
    const aWon =
      pairA === a.pairId ? match.scoreA > match.scoreB : match.scoreB > match.scoreA
    return aWon ? -1 : 1
  }
  return 0
}

function compareRowsWith(
  a: ClassicStanding,
  b: ClassicStanding,
  groupMatches: readonly ClassicMatch[],
): number {
  const base = compareRows(a, b)
  if (base !== 0) return base
  return headToHead(a, b, groupMatches)
}

/** Stable insertion sort over at most four rows, like v1 `Array.sort`. */
function sortStandings(
  rows: ClassicStanding[],
  groupMatches: readonly ClassicMatch[],
): void {
  for (let index = 1; index < rows.length; index += 1) {
    let cursor = index
    while (
      cursor > 0 &&
      compareRowsWith(rows[cursor - 1], rows[cursor], groupMatches) > 0
    ) {
      const held = rows[cursor - 1]
      rows[cursor - 1] = rows[cursor]
      rows[cursor] = held
      cursor -= 1
    }
  }
}

/**
 * Standings for one group: wins, then point difference, then points for, then
 * the first head-to-head meeting. Unplayed matches count for nothing and a
 * match whose pair is not in `pairIds` is ignored.
 */
export function computeGroupStandings(
  groupId: GroupId,
  pairIds: readonly string[],
  matches: readonly ClassicMatch[],
): ClassicStanding[] {
  const groupMatches = matches.filter(
    (match) => match.phase === 'group' && match.groupId === groupId,
  )
  const rows = new Map<string, ClassicStanding>()
  for (const pairId of pairIds) {
    if (rows.has(pairId)) continue
    rows.set(pairId, {
      pairId,
      wins: 0,
      losses: 0,
      pointsFor: 0,
      pointsAgainst: 0,
      diff: 0,
    })
  }
  for (const match of groupMatches) {
    if (match.scoreA === null || match.scoreB === null) continue
    if (match.pairAId === null || match.pairBId === null) continue
    const rowA = rows.get(match.pairAId)
    const rowB = rows.get(match.pairBId)
    if (rowA === undefined || rowB === undefined) continue
    tallyMatch(rowA, match.scoreA, match.scoreB)
    tallyMatch(rowB, match.scoreB, match.scoreA)
  }
  const standings = [...rows.values()]
  for (const row of standings) {
    row.diff = row.pointsFor - row.pointsAgainst
  }
  sortStandings(standings, groupMatches)
  return standings
}

function slotPair(rows: readonly ClassicStanding[], index: number): string | null {
  if (index < 0 || index >= rows.length) return null
  return rows[index].pairId
}

function winnerOf(matches: readonly ClassicMatch[], id: string): string | null {
  const match = matches.find((candidate) => candidate.id === id)
  return match === undefined ? null : matchWinner(match)
}

function loserOf(matches: readonly ClassicMatch[], id: string): string | null {
  const match = matches.find((candidate) => candidate.id === id)
  return match === undefined ? null : matchLoser(match)
}

/**
 * v1 `update`: changing either side clears the score; an unchanged pairing
 * keeps it.
 */
function updateMatch(
  matches: ClassicMatch[],
  id: string,
  pairAId: string | null,
  pairBId: string | null,
): void {
  const match = matches.find((candidate) => candidate.id === id)
  if (match === undefined) return
  if (match.pairAId !== pairAId || match.pairBId !== pairBId) {
    match.scoreA = null
    match.scoreB = null
  }
  match.pairAId = pairAId
  match.pairBId = pairBId
}

/**
 * v1 `propagateBracket`: seed the QF from the group standings (A1-B2, C2-D1,
 * C1-D2, A2-B1), then push winners and losers forward. Standings are computed
 * once, before any update.
 */
export function propagateBracket(
  matches: readonly ClassicMatch[],
  groups: Record<GroupId, string[]>,
): ClassicMatch[] {
  const result = matches.map((match) => ({ ...match }))
  const a = computeGroupStandings('A', groups.A ?? [], result)
  const b = computeGroupStandings('B', groups.B ?? [], result)
  const c = computeGroupStandings('C', groups.C ?? [], result)
  const d = computeGroupStandings('D', groups.D ?? [], result)
  updateMatch(result, QF_IDS[0], slotPair(a, 0), slotPair(b, 1))
  updateMatch(result, QF_IDS[1], slotPair(c, 1), slotPair(d, 0))
  updateMatch(result, QF_IDS[2], slotPair(c, 0), slotPair(d, 1))
  updateMatch(result, QF_IDS[3], slotPair(a, 1), slotPair(b, 0))
  updateMatch(result, SF_IDS[0], winnerOf(result, QF_IDS[0]), winnerOf(result, QF_IDS[1]))
  updateMatch(result, SF_IDS[1], winnerOf(result, QF_IDS[2]), winnerOf(result, QF_IDS[3]))
  updateMatch(result, FINAL_ID, winnerOf(result, SF_IDS[0]), winnerOf(result, SF_IDS[1]))
  updateMatch(result, THIRD_PLACE_ID, loserOf(result, SF_IDS[0]), loserOf(result, SF_IDS[1]))
  return result
}

/**
 * A complete, unscored snapshot: drawn groups, 24 group matches, the knockout
 * skeleton, and QF references seeded from the initial standings. With no score
 * every row is tied, so the stable sort keeps the group order and the QF slots
 * resolve to A1/B2, C2/D1, C1/D2 and A2/B1.
 */
export function generateTournament(
  name: string,
  date: string,
  pairs: Pair[],
  seed: number,
): ClassicSnapshot {
  const groups = drawGroups(
    pairs.map((pair) => pair.id),
    seed,
  )
  const matches = GROUP_IDS.flatMap((groupId) =>
    generateGroupMatches(groupId, groups[groupId]),
  )
  matches.push(...initKnockoutMatches())
  return {
    format: 'classic',
    name,
    date,
    pairs,
    groups,
    matches: propagateBracket(matches, groups),
  }
}

/** True when two snapshots' match rows are identical (propagation no-op). */
export function sameMatches(
  a: readonly ClassicMatch[],
  b: readonly ClassicMatch[],
): boolean {
  if (a.length !== b.length) return false
  return a.every((match, index) => {
    const other = b[index]
    return (
      match.id === other.id &&
      match.phase === other.phase &&
      match.groupId === other.groupId &&
      match.pairAId === other.pairAId &&
      match.pairBId === other.pairBId &&
      match.scoreA === other.scoreA &&
      match.scoreB === other.scoreB
    )
  })
}
