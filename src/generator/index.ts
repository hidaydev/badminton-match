import type { Player, FixMatch, ScheduleSlot } from '../store'

interface State {
  playCount: Record<string, number>
  sitCount: Record<string, number>
  partnerWith: Record<string, Record<string, number>>
  facedBy: Record<string, Record<string, number>>
}

function initState(ids: string[]): State {
  return {
    playCount: Object.fromEntries(ids.map((id) => [id, 0])),
    sitCount: Object.fromEntries(ids.map((id) => [id, 0])),
    partnerWith: {},
    facedBy: {},
  }
}

function inc2(obj: Record<string, Record<string, number>>, a: string, b: string) {
  obj[a] ??= {}
  obj[a][b] = (obj[a][b] ?? 0) + 1
  obj[b] ??= {}
  obj[b][a] = (obj[b][a] ?? 0) + 1
}

function recordGame(a1: string, a2: string, b1: string, b2: string, s: State) {
  s.playCount[a1]++; s.playCount[a2]++
  s.playCount[b1]++; s.playCount[b2]++
  inc2(s.partnerWith, a1, a2)
  inc2(s.partnerWith, b1, b2)
  inc2(s.facedBy, a1, b1); inc2(s.facedBy, a1, b2)
  inc2(s.facedBy, a2, b1); inc2(s.facedBy, a2, b2)
}

function scoreGame(
  a1: string, a2: string, b1: string, b2: string,
  s: State,
  tierMap: Record<string, number>
): number {
  const p = s.partnerWith
  const f = s.facedBy
  const tierDiff = Math.abs(
    (tierMap[a1] ?? 2) + (tierMap[a2] ?? 2) -
    (tierMap[b1] ?? 2) - (tierMap[b2] ?? 2)
  )
  return (
    (p[a1]?.[a2] ?? 0) * 3 +
    (p[b1]?.[b2] ?? 0) * 3 +
    (f[a1]?.[b1] ?? 0) + (f[a1]?.[b2] ?? 0) +
    (f[a2]?.[b1] ?? 0) + (f[a2]?.[b2] ?? 0) +
    tierDiff * 2
  )
}

function bestPairing(
  p: [string, string, string, string],
  s: State,
  tierMap: Record<string, number>
): [string, string, string, string] {
  const options: [string, string, string, string][] = [
    [p[0], p[1], p[2], p[3]],
    [p[0], p[2], p[1], p[3]],
    [p[0], p[3], p[1], p[2]],
  ]
  return options.reduce((best, opt) =>
    scoreGame(...opt, s, tierMap) < scoreGame(...best, s, tierMap) ? opt : best
  )
}

function shuffle<T>(arr: T[]): T[] {
  const a = [...arr]
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[a[i], a[j]] = [a[j], a[i]]
  }
  return a
}

function bestGrouping(players: string[], courts: number, s: State, tierMap: Record<string, number>, tries = 40): string[][] {
  let best: string[][] = []
  let bestScore = Infinity
  for (let t = 0; t < tries; t++) {
    const shuffled = shuffle(players)
    const groups = Array.from({ length: courts }, (_, i) => shuffled.slice(i * 4, (i + 1) * 4))
    const score = groups.reduce((sum, g) => {
      const [a1, a2, b1, b2] = bestPairing(g as [string, string, string, string], s, tierMap)
      return sum + scoreGame(a1, a2, b1, b2, s, tierMap)
    }, 0)
    if (score < bestScore) { bestScore = score; best = groups }
  }
  return best
}

type Game = { teamA: [string, string]; teamB: [string, string] }

function getUsedAtT(grid: (Game | null)[][], t: number, slotsPerCourt: number[]): Set<string> {
  const used = new Set<string>()
  for (let c = 0; c < slotsPerCourt.length; c++) {
    if (t < slotsPerCourt[c] && grid[c][t]) {
      grid[c][t]!.teamA.forEach((p) => used.add(p))
      grid[c][t]!.teamB.forEach((p) => used.add(p))
    }
  }
  return used
}

// Fill the 2 empty slots on the "any" side using best available players
function fillGame(
  slots: [string, string, string, string],
  available: string[],
  state: State,
  tierMap: Record<string, number>,
  totalFixCommitments: Record<string, number> = {},
  fixPlayCount: Record<string, number> = {}
): [string, string, string, string] | null {
  const [a1, a2, b1, b2] = slots
  const fixed = [a1, a2, b1, b2].filter(Boolean)
  const pool = available.filter((id) => !fixed.includes(id))

  const projected = (id: string) => state.playCount[id] + Math.max(0, (totalFixCommitments[id] ?? 0) - (fixPlayCount[id] ?? 0))
  const sorted = [...pool].sort((a, b) => projected(a) - projected(b) || state.sitCount[b] - state.sitCount[a] || Math.random() - 0.5)

  // Count how many empty slots we need to fill
  const empty = [!a1, !a2, !b1, !b2]
  const needed = empty.filter(Boolean).length
  const emptyIndices = empty.map((e, k) => (e ? k : -1)).filter((k) => k >= 0)

  // Fully specified — return as-is
  if (needed === 0) return [a1, a2, b1, b2] as [string, string, string, string]

  if (sorted.length < needed) return null

  // Try top candidates (up to 8) to find the best fill
  const candidates = sorted.slice(0, Math.min(8, sorted.length))

  if (needed === 2) {
    let bestGame: [string, string, string, string] | null = null
    let bestScore = Infinity
    for (let i = 0; i < candidates.length; i++) {
      for (let j = i + 1; j < candidates.length; j++) {
        const filled = [a1, a2, b1, b2].map((v, idx) => {
          if (v) return v
          return idx === emptyIndices[0] ? candidates[i] : candidates[j]
        }) as [string, string, string, string]
        const s = scoreGame(...filled, state, tierMap)
        if (s < bestScore) { bestScore = s; bestGame = filled }
      }
    }
    return bestGame
  }

  if (needed === 1) {
    let bestGame: [string, string, string, string] | null = null
    let bestScore = Infinity
    const emptyIdx = empty.findIndex(Boolean)
    for (const c of candidates) {
      const filled = [a1, a2, b1, b2].map((v, idx) => (idx === emptyIdx ? c : v)) as [string, string, string, string]
      const s = scoreGame(...filled, state, tierMap)
      if (s < bestScore) { bestScore = s; bestGame = filled }
    }
    return bestGame
  }

  if (needed === 3) {
    let bestGame: [string, string, string, string] | null = null
    let bestScore = Infinity
    for (let i = 0; i < candidates.length; i++) {
      for (let j = i + 1; j < candidates.length; j++) {
        for (let k = j + 1; k < candidates.length; k++) {
          const picks = [candidates[i], candidates[j], candidates[k]]
          const filled = [...slots] as [string, string, string, string]
          emptyIndices.forEach((idx, n) => { filled[idx] = picks[n] })
          const s = scoreGame(...filled, state, tierMap)
          if (s < bestScore) { bestScore = s; bestGame = filled }
        }
      }
    }
    return bestGame
  }

  return null
}

export interface GeneratorResult {
  schedule: ScheduleSlot[]
  playCount: Record<string, number>
  sitCount: Record<string, number>
  partnerWith: Record<string, Record<string, number>>
  facedBy: Record<string, Record<string, number>>
  unplacedFixMatches: string[] // ids of fix matches that couldn't be placed
}

export function generate(
  players: Player[],
  slotsPerCourt: number[],
  fixMatches: FixMatch[]
): GeneratorResult {
  const ids = players.map((p) => p.id)
  const tierMap: Record<string, number> = Object.fromEntries(players.map((p) => [p.id, p.tier]))
  const numCourts = slotsPerCourt.length
  const maxSlots = Math.max(...slotsPerCourt)
  const state = initState(ids)
  const grid: (Game | null)[][] = slotsPerCourt.map((n) => Array(n).fill(null))
  const unplacedFixMatches: string[] = []

  // Sort fix matches: most specified first (full matches placed before partial)
  const sorted = [...fixMatches].sort(
    (a, b) => b.slots.filter(Boolean).length - a.slots.filter(Boolean).length
  )

  // Precompute total fix match appearances per player so greedy fill can deprioritize them
  const totalFixCommitments: Record<string, number> = Object.fromEntries(ids.map((id) => [id, 0]))
  for (const fm of fixMatches) {
    fm.slots.filter(Boolean).forEach((id) => { if (id) totalFixCommitments[id]++ })
  }
  const fixPlayCount: Record<string, number> = Object.fromEntries(ids.map((id) => [id, 0]))

  // Spread fix matches with the same players evenly across slots
  const fixGroups = new Map<string, FixMatch[]>()
  for (const fm of sorted) {
    const key = fm.slots.filter(Boolean).sort().join('|')
    if (!fixGroups.has(key)) fixGroups.set(key, [])
    fixGroups.get(key)!.push(fm)
  }
  const targetSlot = new Map<string, number>()
  for (const group of fixGroups.values()) {
    group.forEach((fm, i) => {
      targetSlot.set(fm.id, Math.round((i / group.length) * maxSlots))
    })
  }

  // ── Place fix matches ────────────────────────────────────────────────────────
  for (const fm of sorted) {
    const specifiedCount = fm.slots.filter(Boolean).length
    if (specifiedCount === 0) continue

    const target = targetSlot.get(fm.id) ?? 0
    const specifiedPlayers = fm.slots.filter(Boolean)
    const isBackToBack = (t: number) =>
      [t - 1, t + 1].some((adj) => {
        if (adj < 0 || adj >= maxSlots) return false
        const used = getUsedAtT(grid, adj, slotsPerCourt)
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
        if (t >= slotsPerCourt[c] || grid[c][t] !== null) continue

        const usedAtT = getUsedAtT(grid, t, slotsPerCourt)

        if (specifiedPlayers.some((p) => usedAtT.has(p))) continue

        const available = ids.filter((id) => !usedAtT.has(id))
        const game = fillGame(fm.slots, available, state, tierMap, totalFixCommitments, fixPlayCount)

        if (!game) continue

        grid[c][t] = { teamA: [game[0], game[1]], teamB: [game[2], game[3]] }
        recordGame(game[0], game[1], game[2], game[3], state)
        fm.slots.filter(Boolean).forEach((id) => { if (id) fixPlayCount[id]++ })
        placed = true
        break outer
      }
    }

    if (!placed) unplacedFixMatches.push(fm.id)
  }

  // ── Fill remaining slots greedily ────────────────────────────────────────────
  for (let t = 0; t < maxSlots; t++) {
    const activeCourts = slotsPerCourt.map((n, c) => (t < n ? c : -1)).filter((c) => c >= 0)
    const unfilledCourts = activeCourts.filter((c) => grid[c][t] === null)
    if (unfilledCourts.length === 0) continue

    const usedAtT = getUsedAtT(grid, t, slotsPerCourt)
    const available = ids.filter((id) => !usedAtT.has(id))
    const need = unfilledCourts.length * 4

    // Players not in any game this slot sit out (includes fix-match-only slots)
    if (need === 0) {
      for (const id of available) state.sitCount[id]++
      continue
    }

    if (available.length < need) continue

    const projected = (id: string) => state.playCount[id] + (totalFixCommitments[id] - fixPlayCount[id])
    const sortedAvail = [...available].sort(
      (a, b) => projected(a) - projected(b) || state.sitCount[b] - state.sitCount[a] || Math.random() - 0.5
    )

    const playing = sortedAvail.slice(0, need)
    const sittingOut = sortedAvail.slice(need)
    for (const id of sittingOut) state.sitCount[id]++

    const groups = bestGrouping(playing, unfilledCourts.length, state, tierMap)
    for (let i = 0; i < unfilledCourts.length; i++) {
      const group = groups[i] as [string, string, string, string]
      const [a1, a2, b1, b2] = bestPairing(group, state, tierMap)
      grid[unfilledCourts[i]][t] = { teamA: [a1, a2], teamB: [b1, b2] }
      recordGame(a1, a2, b1, b2, state)
    }
  }

  // ── Flatten to ScheduleSlot[] ────────────────────────────────────────────────
  const schedule: ScheduleSlot[] = []
  for (let c = 0; c < numCourts; c++) {
    for (let t = 0; t < slotsPerCourt[c]; t++) {
      if (grid[c][t]) {
        const g = grid[c][t]!
        schedule.push({ slot: t, court: c, teamA: g.teamA, teamB: g.teamB })
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
