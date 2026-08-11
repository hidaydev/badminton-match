import type { Player, MatchConstraint, MatchConstraintPinned, ScheduleSlot, PlayerId } from '../types'
import { toPlayerId } from '../types'
import { bumpCoOccurrence } from '../utils/counter'
import { shuffle, combinations } from '../utils/array'
import { DEFAULT_SCORING, DEFAULT_TIER, GROUPING_TRIES, FILL_CANDIDATES, type ScoringWeights } from '../config/generator'

interface GeneratorState {
  playCount: Record<PlayerId, number>
  sitCount: Record<PlayerId, number>
  partnerWith: Record<PlayerId, Record<PlayerId, number>>
  facedBy: Record<PlayerId, Record<PlayerId, number>>
}

function initState(ids: string[]): GeneratorState {
  return {
    playCount: Object.fromEntries(ids.map((id) => [toPlayerId(id), 0])) as Record<PlayerId, number>,
    sitCount: Object.fromEntries(ids.map((id) => [toPlayerId(id), 0])) as Record<PlayerId, number>,
    partnerWith: {} as Record<PlayerId, Record<PlayerId, number>>,
    facedBy: {} as Record<PlayerId, Record<PlayerId, number>>,
  }
}

function recordScheduledGame(a1: string, a2: string, b1: string, b2: string, state: GeneratorState) {
  const id1 = toPlayerId(a1), id2 = toPlayerId(a2), id3 = toPlayerId(b1), id4 = toPlayerId(b2)
  state.playCount[id1]++; state.playCount[id2]++
  state.playCount[id3]++; state.playCount[id4]++
  bumpCoOccurrence(state.partnerWith, id1, id2)
  bumpCoOccurrence(state.partnerWith, id3, id4)
  bumpCoOccurrence(state.facedBy, id1, id3); bumpCoOccurrence(state.facedBy, id1, id4)
  bumpCoOccurrence(state.facedBy, id2, id3); bumpCoOccurrence(state.facedBy, id2, id4)
}

interface ScoreGameOptions {
  teamA: [string, string]
  teamB: [string, string]
  state: GeneratorState
  tierMap: Record<string, number>
  scoring?: ScoringWeights
}

function scoreScheduledGame(options: ScoreGameOptions): number {
  const { teamA, teamB, state, tierMap, scoring = DEFAULT_SCORING } = options
  const [a1, a2] = teamA
  const [b1, b2] = teamB
  const partners = state.partnerWith
  const opponents = state.facedBy
  const tierDiff = Math.abs(
    (tierMap[a1] ?? DEFAULT_TIER) + (tierMap[a2] ?? DEFAULT_TIER) -
    (tierMap[b1] ?? DEFAULT_TIER) - (tierMap[b2] ?? DEFAULT_TIER)
  )
  const id1 = toPlayerId(a1), id2 = toPlayerId(a2), id3 = toPlayerId(b1), id4 = toPlayerId(b2)
  return (
    (partners[id1]?.[id2] ?? 0) * scoring.partnerPenalty +
    (partners[id3]?.[id4] ?? 0) * scoring.partnerPenalty +
    (opponents[id1]?.[id3] ?? 0) * scoring.opponentPenalty + (opponents[id1]?.[id4] ?? 0) * scoring.opponentPenalty +
    (opponents[id2]?.[id3] ?? 0) * scoring.opponentPenalty + (opponents[id2]?.[id4] ?? 0) * scoring.opponentPenalty +
    tierDiff * scoring.tierDiffWeight
  )
}

function bestPairing(
  players: [string, string, string, string],
  state: GeneratorState,
  tierMap: Record<string, number>,
  scoring: ScoringWeights = DEFAULT_SCORING,
): [string, string, string, string] {
  const options: [string, string, string, string][] = [
    [players[0], players[1], players[2], players[3]],
    [players[0], players[2], players[1], players[3]],
    [players[0], players[3], players[1], players[2]],
  ]
  return options.reduce((best, opt) =>
    scoreScheduledGame({ teamA: [opt[0], opt[1]], teamB: [opt[2], opt[3]], state, tierMap, scoring }) <
    scoreScheduledGame({ teamA: [best[0], best[1]], teamB: [best[2], best[3]], state, tierMap, scoring })
      ? opt : best
  )
}

function bestGrouping(players: string[], courts: number, state: GeneratorState, tierMap: Record<string, number>, tries = GROUPING_TRIES, scoring: ScoringWeights = DEFAULT_SCORING): string[][] {
  let best: string[][] = []
  let bestScore = Infinity
  for (let t = 0; t < tries; t++) {
    const shuffled = shuffle(players)
    const groups = Array.from({ length: courts }, (_, i) => shuffled.slice(i * 4, (i + 1) * 4))
    const score = groups.reduce((sum, g) => {
      const [a1, a2, b1, b2] = bestPairing(g as [string, string, string, string], state, tierMap, scoring)
      return sum + scoreScheduledGame({ teamA: [a1, a2], teamB: [b1, b2], state, tierMap, scoring })
    }, 0)
    if (score < bestScore) { bestScore = score; best = groups }
  }
  return best
}

type ScheduledGame = { teamA: [string, string]; teamB: [string, string] }

function getUsedAtT(grid: (ScheduledGame | null)[][], t: number, slotsPerCourt: number[], courtOffsets: number[] = []): Set<string> {
  const used = new Set<string>()
  for (let c = 0; c < slotsPerCourt.length; c++) {
    const offset = courtOffsets[c] ?? 0
    if (t >= offset && t < offset + slotsPerCourt[c] && grid[c][t]) {
      grid[c][t]!.teamA.forEach((p) => used.add(p))
      grid[c][t]!.teamB.forEach((p) => used.add(p))
    }
  }
  return used
}

// Fill empty slots using best available players
function fillScheduledGame(
  slots: [string, string, string, string],
  available: string[],
  state: GeneratorState,
  tierMap: Record<string, number>,
  totalFixCommitments: Record<string, number> = {},
  fixPlayCount: Record<string, number> = {},
  scoring: ScoringWeights = DEFAULT_SCORING,
): [string, string, string, string] | null {
  const [a1, a2, b1, b2] = slots
  const fixed = [a1, a2, b1, b2].filter(Boolean)
  const pool = available.filter((id) => !fixed.includes(id))

  const projected = (id: string) => (state.playCount[toPlayerId(id)] ?? 0) + Math.max(0, (totalFixCommitments[id] ?? 0) - (fixPlayCount[id] ?? 0))
  const sorted = [...pool].sort((a, b) => projected(a) - projected(b) || (state.sitCount[toPlayerId(b)] ?? 0) - (state.sitCount[toPlayerId(a)] ?? 0) || Math.random() - 0.5)

  const empty = [!a1, !a2, !b1, !b2]
  const needed = empty.filter(Boolean).length
  const emptyIndices = empty.map((e, k) => (e ? k : -1)).filter((k) => k >= 0)

  if (needed === 0) return [a1, a2, b1, b2] as [string, string, string, string]
  if (sorted.length < needed) return null

  const candidates = sorted.slice(0, Math.min(FILL_CANDIDATES, sorted.length))

  let bestGame: [string, string, string, string] | null = null
  let bestScore = Infinity

  for (const picks of combinations(candidates, needed)) {
    const filled = [...slots] as [string, string, string, string]
    emptyIndices.forEach((idx, n) => { filled[idx] = picks[n] })
    const score = scoreScheduledGame({ teamA: [filled[0], filled[1]], teamB: [filled[2], filled[3]], state, tierMap, scoring })
    if (score < bestScore) { bestScore = score; bestGame = filled }
  }

  return bestGame
}

export interface GeneratorResult {
  schedule: ScheduleSlot[]
  playCount: Record<string, number>
  sitCount: Record<string, number>
  partnerWith: Record<string, Record<string, number>>
  facedBy: Record<string, Record<string, number>>
  unplacedFixMatches: string[] // ids of fix matches that couldn't be placed
}

export interface GeneratorOptions {
  scoring?: ScoringWeights
}

export interface GenerateContext {
  players: Player[]
  slotsPerCourt: number[]
  fixMatches: MatchConstraint[]
  courtOffsets?: number[]
  timeToSlotIndex: (time: string) => number
  options?: GeneratorOptions
}

// ── Phase result types ────────────────────────────────────────────────────────

/** Result of the pinned-match placement phase. */
interface PlacePinnedResult {
  /** IDs of pinned matches that were successfully placed (excluded from later phases). */
  pinnedIds: Set<string>
  /** IDs of pinned matches that could not be placed. */
  unplacedIds: string[]
}

/** Result of the pairable-merge phase. */
interface MergePairableResult {
  /** Effective fix-match list (merges applied, originals removed). */
  effectiveFixes: MatchConstraint[]
  /** Maps merged IDs back to the two original fix-match IDs. */
  mergedSourceIds: Map<string, [string, string]>
}

// ── Shared context untuk fase-fase penempatan ─────────────────────────────
// Menggabungkan field yang di-share antar fase (sebelumnya parameter
// positional 11-14 buah yang rawan salah urut).

interface PhaseContext {
  grid: (ScheduledGame | null)[][]
  slotsPerCourt: number[]
  courtOffsets: number[]
  ids: string[]
  state: GeneratorState
  tierMap: Record<string, number>
  scoring: ScoringWeights
  totalFixCommitments: Record<string, number>
  fixPlayCount: Record<string, number>
}

// ── Phase 1: Pre-place pinned matches ────────────────────────────────────────

/**
 * Place all pinned (time + court locked) fix matches onto the grid.
 *
 * Pinned matches have an exact court and time. For each, the function validates
 * bounds, emptiness, and player conflicts before filling any wildcard slots and
 * writing the game to the grid.
 *
 * @returns The set of pinned IDs (to filter them out of later phases) and any
 *          IDs that could not be placed.
 */
function placePinnedMatches(
  sorted: MatchConstraint[],
  timeToSlotIndexFn: ((time: string) => number) | undefined,
  ctx: PhaseContext,
): PlacePinnedResult {
  const { grid, slotsPerCourt, courtOffsets, ids, state, tierMap, totalFixCommitments, fixPlayCount, scoring } = ctx
  const pinnedMatches: MatchConstraintPinned[] = timeToSlotIndexFn
    ? sorted.filter((fm): fm is MatchConstraintPinned => fm.mode === 'pinned')
    : []
  const pinnedIds = new Set(pinnedMatches.map(fm => fm.id))
  const unplacedIds: string[] = []

  for (const fm of pinnedMatches) {
    const c = fm.pinnedCourt
    const t = timeToSlotIndexFn!(fm.pinnedTime)

    // Validate court index is within bounds
    if (c < 0 || c >= slotsPerCourt.length) {
      unplacedIds.push(fm.id)
      continue
    }

    // Validate slot is within court bounds
    const offset = courtOffsets[c] ?? 0
    if (t < offset || t >= offset + slotsPerCourt[c]) {
      unplacedIds.push(fm.id)
      continue
    }

    // Validate slot is empty
    if (grid[c][t] !== null) {
      unplacedIds.push(fm.id)
      continue
    }

    // Validate no player conflicts
    const usedAtT = getUsedAtT(grid, t, slotsPerCourt, courtOffsets)
    const specifiedPlayers = fm.slots.filter(Boolean)
    if (specifiedPlayers.some(p => usedAtT.has(p))) {
      unplacedIds.push(fm.id)
      continue
    }

    // Fill wildcard slots
    const available = ids.filter(id => !usedAtT.has(id))
    const game = fillScheduledGame(fm.slots, available, state, tierMap, totalFixCommitments, fixPlayCount, scoring)

    if (!game) {
      unplacedIds.push(fm.id)
      continue
    }

    grid[c][t] = { teamA: [game[0], game[1]], teamB: [game[2], game[3]] }
    recordScheduledGame(game[0], game[1], game[2], game[3], state)
    fm.slots.filter(Boolean).forEach(id => { if (id) fixPlayCount[id]++ })
  }

  return { pinnedIds, unplacedIds }
}

// ── Phase 2: Merge pairable fix matches (A-side only) ────────────────────────

/**
 * Merge pairable A-side-only fix matches into full 4-player games.
 *
 * Two fix matches that each specify only team-A players (slots 0+1) and leave
 * team-B open can share a single slot: one pair becomes Team A and the other
 * becomes Team B. Pairs are matched to minimise tier difference.
 *
 * @param flexibleFixes Non-pinned fix matches (already sorted most-specified-first).
 * @param tierMap       Player tier lookup.
 * @returns The effective fix-match list and a map from merged IDs back to sources.
 */
function mergePairableFixMatches(
  flexibleFixes: MatchConstraint[],
  tierMap: Record<string, number>,
): MergePairableResult {
  const isPairable = (fm: MatchConstraint) => !!(fm.slots[0] && fm.slots[1] && !fm.slots[2] && !fm.slots[3])
  const mergedSourceIds = new Map<string, [string, string]>()
  const usedInMerge = new Set<string>()
  const effectiveFixes: MatchConstraint[] = []

  const pairableSorted = shuffle(flexibleFixes.filter(isPairable))
  for (const fm of pairableSorted) {
    if (usedInMerge.has(fm.id)) continue
    let bestPartner: MatchConstraint | null = null
    let bestTierDiff = Infinity
    for (const other of shuffle(pairableSorted)) {
      if (usedInMerge.has(other.id) || other.id === fm.id) continue
      if (fm.slots[0] === other.slots[0] || fm.slots[0] === other.slots[1] ||
          fm.slots[1] === other.slots[0] || fm.slots[1] === other.slots[1]) continue
      const diff = Math.abs(
        (tierMap[fm.slots[0]] ?? 2) + (tierMap[fm.slots[1]] ?? 2) -
        (tierMap[other.slots[0]] ?? 2) - (tierMap[other.slots[1]] ?? 2)
      )
      if (diff < bestTierDiff) { bestTierDiff = diff; bestPartner = other }
    }
    if (bestPartner) {
      const mergedId = `__merged_${fm.id}_${bestPartner.id}`
      effectiveFixes.push({ id: mergedId, slots: [fm.slots[0], fm.slots[1], bestPartner.slots[0], bestPartner.slots[1]], mode: 'flexible' })
      mergedSourceIds.set(mergedId, [fm.id, bestPartner.id])
      usedInMerge.add(fm.id)
      usedInMerge.add(bestPartner.id)
    }
  }
  // Add non-pairable and unmerged fix matches
  for (const fm of flexibleFixes) {
    if (!usedInMerge.has(fm.id)) effectiveFixes.push(fm)
  }
  effectiveFixes.sort((a, b) => b.slots.filter(Boolean).length - a.slots.filter(Boolean).length)

  return { effectiveFixes, mergedSourceIds }
}

// ── Phase 3: Spread fix matches across slots ─────────────────────────────────

/**
 * Compute a target slot index for each effective fix match so that matches
 * with the same player set are spread evenly across the session.
 *
 * @param effectiveFixes Merged fix-match list.
 * @param maxSlots       Total number of time slots in the session.
 * @returns Map from fix-match ID to its preferred slot index.
 */
function spreadFixMatches(
  effectiveFixes: MatchConstraint[],
  maxSlots: number,
): Map<string, number> {
  const fixGroups = new Map<string, MatchConstraint[]>()
  for (const fm of effectiveFixes) {
    const key = fm.slots.filter(Boolean).sort().join('|')
    if (!fixGroups.has(key)) fixGroups.set(key, [])
    fixGroups.get(key)!.push(fm)
  }
  const targetSlot = new Map<string, number>()
  for (const group of fixGroups.values()) {
    group.forEach((fm, i) => {
      targetSlot.set(fm.id, Math.min(Math.round((i / group.length) * maxSlots), maxSlots - 1))
    })
  }
  return targetSlot
}

// ── Phase 4: Place flexible fix matches ──────────────────────────────────────

/**
 * Place non-pinned, non-merged (or merged) flexible fix matches onto the grid.
 *
 * For each fix match the function tries slots in order of preference: avoiding
 * back-to-back appearances for the same players, closest to the target slot
 * computed by {@link spreadFixMatches}. Wildcard positions are filled by the
 * scoring-aware {@link fillScheduledGame} helper.
 *
 * @returns IDs of fix matches (original, not merged) that could not be placed.
 */
function placeFlexibleFixMatches(
  effectiveFixes: MatchConstraint[],
  maxSlots: number,
  targetSlot: Map<string, number>,
  mergedSourceIds: Map<string, [string, string]>,
  ctx: PhaseContext,
): string[] {
  const { grid, slotsPerCourt, courtOffsets, ids, state, tierMap, scoring, totalFixCommitments, fixPlayCount } = ctx
  const numCourts = slotsPerCourt.length
  const unplacedIds: string[] = []

  for (const fm of effectiveFixes) {
    const specifiedCount = fm.slots.filter(Boolean).length
    if (specifiedCount === 0) continue

    const target = targetSlot.get(fm.id) ?? 0
    const specifiedPlayers = fm.slots.filter(Boolean)
    const isBackToBack = (t: number) =>
      [t - 1, t + 1].some((adj) => {
        if (adj < 0 || adj >= maxSlots) return false
        const used = getUsedAtT(grid, adj, slotsPerCourt, courtOffsets)
        return specifiedPlayers.some((p) => used.has(p))
      })
    const slotOrder = Array.from({ length: maxSlots }, (_, t) => t)
      .sort((a, b) =>
        (isBackToBack(a) ? 1 : 0) - (isBackToBack(b) ? 1 : 0) ||
        Math.abs(a - target) - Math.abs(b - target) ||
        a - b
      )

    let placed = false
    outer: for (const t of slotOrder) {
      for (let c = 0; c < numCourts && !placed; c++) {
        const offset = courtOffsets[c] ?? 0
        if (t < offset || t >= offset + slotsPerCourt[c] || grid[c][t] !== null) continue

        const usedAtT = getUsedAtT(grid, t, slotsPerCourt, courtOffsets)

        if (specifiedPlayers.some((p) => usedAtT.has(p))) continue

        const available = ids.filter((id) => !usedAtT.has(id))
        const game = fillScheduledGame(fm.slots, available, state, tierMap, totalFixCommitments, fixPlayCount, scoring)

        if (!game) continue

        grid[c][t] = { teamA: [game[0], game[1]], teamB: [game[2], game[3]] }
        recordScheduledGame(game[0], game[1], game[2], game[3], state)
        fm.slots.filter(Boolean).forEach((id) => { if (id) fixPlayCount[id]++ })
        placed = true
        break outer
      }
    }

    if (!placed) {
      const sourceIds = mergedSourceIds.get(fm.id)
      if (sourceIds) unplacedIds.push(...sourceIds)
      else unplacedIds.push(fm.id)
    }
  }

  return unplacedIds
}

// ── Phase 5: Greedy fill remaining slots ─────────────────────────────────────

/**
 * Fill every remaining empty grid slot with the best available players.
 *
 * Players are sorted by projected play count (actual + pending fix commitments),
 * recency of last slot, and sit count. The {@link bestGrouping} and
 * {@link bestPairing} helpers optimise court assignments for balanced play and
 * tier fairness.
 *
 * Players who are available but not needed for a slot have their sit count
 * incremented.
 */
function greedyFillRemaining(
  maxSlots: number,
  ctx: PhaseContext,
): void {
  const { grid, slotsPerCourt, courtOffsets, ids, state, tierMap, scoring, totalFixCommitments, fixPlayCount } = ctx
  for (let t = 0; t < maxSlots; t++) {
    const activeCourts = slotsPerCourt.map((n, c) => {
      const offset = courtOffsets[c] ?? 0
      return (t >= offset && t < offset + n) ? c : -1
    }).filter((c) => c >= 0)
    const unfilledCourts = activeCourts.filter((c) => grid[c][t] === null)
    if (unfilledCourts.length === 0) continue

    const usedAtT = getUsedAtT(grid, t, slotsPerCourt, courtOffsets)
    const available = ids.filter((id) => !usedAtT.has(id))
    const need = unfilledCourts.length * 4

    // Players not in any game this slot sit out (includes fix-match-only slots)
    if (need === 0) {
      for (const id of available) state.sitCount[toPlayerId(id)]++
      continue
    }

    if (available.length < need) {
      // Increment sitCount for available players who can't fill this slot
      for (const id of available) {
        const pid = toPlayerId(id)
        state.sitCount[pid] = (state.sitCount[pid] ?? 0) + 1
      }
      continue
    }

    const projected = (id: string) => (state.playCount[toPlayerId(id)] ?? 0) + (totalFixCommitments[id] - fixPlayCount[id])
    const playedLastSlot = (id: string) => t > 0 ? getUsedAtT(grid, t - 1, slotsPerCourt, courtOffsets).has(id) : false
    const sortedAvail = [...available].sort(
      (a, b) => projected(a) - projected(b) || (playedLastSlot(a) ? 1 : 0) - (playedLastSlot(b) ? 1 : 0) || (state.sitCount[toPlayerId(b)] ?? 0) - (state.sitCount[toPlayerId(a)] ?? 0) || Math.random() - 0.5
    )

    const playing = sortedAvail.slice(0, need)
    const sittingOut = sortedAvail.slice(need)
    for (const id of sittingOut) state.sitCount[toPlayerId(id)]++

    const groups = bestGrouping(playing, unfilledCourts.length, state, tierMap, GROUPING_TRIES, scoring)
    for (let i = 0; i < unfilledCourts.length; i++) {
      const group = groups[i] as [string, string, string, string]
      const [a1, a2, b1, b2] = bestPairing(group, state, tierMap, scoring)
      grid[unfilledCourts[i]][t] = { teamA: [a1, a2], teamB: [b1, b2] }
      recordScheduledGame(a1, a2, b1, b2, state)
    }
  }
}

// ── Orchestrator ─────────────────────────────────────────────────────────────

export function generate(ctx: GenerateContext): GeneratorResult {
  const { players, slotsPerCourt, fixMatches, timeToSlotIndex, options } = ctx
  const courtOffsets = ctx.courtOffsets ?? []
  const scoring = options?.scoring ?? DEFAULT_SCORING
  const ids = players.map((p) => p.id)
  const tierMap: Record<string, number> = Object.fromEntries(players.map((p) => [p.id, p.tier]))
  const numCourts = slotsPerCourt.length
  const maxSlots = Math.max(...slotsPerCourt.map((n, c) => (courtOffsets[c] ?? 0) + n))

  // Guard: no courts or no time slots → return empty schedule
  if (slotsPerCourt.length === 0 || maxSlots <= 0) {
    return {
      schedule: [],
      playCount: {},
      sitCount: {},
      partnerWith: {},
      facedBy: {},
      unplacedFixMatches: fixMatches.map(f => f.id),
    }
  }

  const state = initState(ids)
  const grid: (ScheduledGame | null)[][] = slotsPerCourt.map(() => Array(maxSlots).fill(null))
  const unplacedFixMatches: string[] = []

  // Sort fix matches: most specified first (full matches placed before partial)
  const sorted = [...fixMatches].sort(
    (a, b) => b.slots.filter(Boolean).length - a.slots.filter(Boolean).length
  )

  // Precompute total fix match appearances per player so greedy fill can deprioritize them
  const totalFixCommitments: Record<string, number> = Object.fromEntries(ids.map((id) => [id, 0]))
  for (const fm of fixMatches) {
    fm.slots.filter(Boolean).forEach((id: string) => { if (id) totalFixCommitments[id]++ })
  }
  const fixPlayCount: Record<string, number> = Object.fromEntries(ids.map((id) => [id, 0]))

  // Shared context untuk semua fase penempatan
  const phaseCtx: PhaseContext = {
    grid,
    slotsPerCourt,
    courtOffsets,
    ids,
    state,
    tierMap,
    scoring,
    totalFixCommitments,
    fixPlayCount,
  }

  // Phase 1 — Pre-place pinned matches
  const { pinnedIds, unplacedIds: pinnedUnplaced } = placePinnedMatches(sorted, timeToSlotIndex, phaseCtx)
  unplacedFixMatches.push(...pinnedUnplaced)

  // Filter out pinned matches from further processing
  const flexibleFixes = sorted.filter(fm => !pinnedIds.has(fm.id))

  // Phase 2 — Merge pairable fix matches (A-side only) into single games
  const { effectiveFixes, mergedSourceIds } = mergePairableFixMatches(flexibleFixes, tierMap)

  // Phase 3 — Spread fix matches with the same players evenly across slots
  const targetSlot = spreadFixMatches(effectiveFixes, maxSlots)

  // Phase 4 — Place flexible fix matches
  const flexibleUnplaced = placeFlexibleFixMatches(effectiveFixes, maxSlots, targetSlot, mergedSourceIds, phaseCtx)
  unplacedFixMatches.push(...flexibleUnplaced)

  // Phase 5 — Fill remaining slots greedily
  greedyFillRemaining(maxSlots, phaseCtx)

  // ── Flatten to ScheduleSlot[] ────────────────────────────────────────────────
  const schedule: ScheduleSlot[] = []
  for (let c = 0; c < numCourts; c++) {
    const offset = courtOffsets[c] ?? 0
    for (let t = offset; t < offset + slotsPerCourt[c]; t++) {
      if (grid[c][t]) {
        const g = grid[c][t]!
        schedule.push({
          slot: t,
          court: c,
          teamA: [toPlayerId(g.teamA[0]), toPlayerId(g.teamA[1])],
          teamB: [toPlayerId(g.teamB[0]), toPlayerId(g.teamB[1])],
        })
      }
    }
  }

  return {
    schedule,
    playCount: state.playCount,
    sitCount: state.sitCount,
    partnerWith: state.partnerWith,
    facedBy: state.facedBy,
    unplacedFixMatches,
  }
}
