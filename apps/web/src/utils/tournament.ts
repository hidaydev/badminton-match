import { shuffle } from './array'
import { initTallyRow, tallyMatch, computeDiff, standardStandingSort, type TallyRow } from './tally'

export type GroupId = 'A' | 'B' | 'C' | 'D'
type MatchPhase = 'group' | 'qf' | 'sf' | '3rd' | 'final'

/** Urutan grup kanonik (A–D) — single source of truth untuk seluruh UI/kueri. */
export const GROUP_IDS: GroupId[] = ['A', 'B', 'C', 'D']

/** Grup kosong (4 grup) — default read-only; clone bila perlu dimutasi. */
export const EMPTY_GROUPS: Record<GroupId, string[]> = { A: [], B: [], C: [], D: [] }

/** Id match knockout — single source of truth (bracket/klasemen/propagasi). */
export const QF_IDS = ['qf-1', 'qf-2', 'qf-3', 'qf-4'] as const
export const SF_IDS = ['sf-1', 'sf-2'] as const
export const FINAL_ID = 'final-1'
export const THIRD_PLACE_ID = '3rd-1'

export interface TournamentPair {
  id: string
  name: string
}

export interface TournamentMatch {
  id: string
  phase: MatchPhase
  groupId?: GroupId
  pairAId: string | null
  pairBId: string | null
  scoreA: number | null
  scoreB: number | null
  picName?: string | null
}

export interface StandingRow extends TallyRow {
  pairId: string
}

export interface TournamentSnapshot {
  version?: number
  format?: 'classic'
  name: string
  date: string
  pairs: TournamentPair[]
  groups: Record<GroupId, string[]>
  matches: TournamentMatch[]
}

// Round-robin pairings for 4 teams (indices into pairIds array)
const RR: [number, number][] = [[0,1],[2,3],[0,2],[1,3],[0,3],[1,2]]

export function generateGroupMatches(groupId: GroupId, pairIds: string[]): TournamentMatch[] {
  return RR.map(([i, j], idx) => ({
    id: `group-${groupId}-${idx}`,
    phase: 'group' as const,
    groupId,
    pairAId: pairIds[i],
    pairBId: pairIds[j],
    scoreA: null,
    scoreB: null,
  }))
}

export function initKnockoutMatches(): TournamentMatch[] {
  const ko = (id: string, phase: MatchPhase): TournamentMatch => ({
    id, phase, pairAId: null, pairBId: null, scoreA: null, scoreB: null,
  })
  return [
    ...QF_IDS.map((id) => ko(id, 'qf')),
    ...SF_IDS.map((id) => ko(id, 'sf')),
    ko(THIRD_PLACE_ID, '3rd'),
    ko(FINAL_ID, 'final'),
  ]
}

function getMatchWinner(match: TournamentMatch): string | null {
  if (match.scoreA === null || match.scoreB === null || !match.pairAId || !match.pairBId) return null
  return match.scoreA > match.scoreB ? match.pairAId : match.pairBId
}

function getMatchLoser(match: TournamentMatch): string | null {
  if (match.scoreA === null || match.scoreB === null || !match.pairAId || !match.pairBId) return null
  return match.scoreA < match.scoreB ? match.pairAId : match.pairBId
}

export function computeGroupStandings(
  groupId: GroupId,
  pairIds: string[],
  matches: TournamentMatch[]
): StandingRow[] {
  const groupMatches = matches.filter((m) => m.phase === 'group' && m.groupId === groupId)
  const rows: Record<string, StandingRow> = {}
  for (const id of pairIds) {
    rows[id] = { ...initTallyRow(), pairId: id }
  }

  for (const m of groupMatches) {
    if (m.scoreA === null || m.scoreB === null || !m.pairAId || !m.pairBId) continue
    const a = rows[m.pairAId]
    const b = rows[m.pairBId]
    if (!a || !b) continue
    tallyMatch(a, m.scoreA, m.scoreB)
    tallyMatch(b, m.scoreB, m.scoreA)
  }

  for (const row of Object.values(rows)) computeDiff(row)

  return Object.values(rows).sort((a, b) => {
    const base = standardStandingSort(a, b)
    if (base !== 0) return base
    // head-to-head — always decisive since draws are impossible
    const h2h = groupMatches.find(
      (m) =>
        (m.pairAId === a.pairId && m.pairBId === b.pairId) ||
        (m.pairAId === b.pairId && m.pairBId === a.pairId)
    )
    if (h2h?.scoreA !== null && h2h?.scoreB !== null && h2h?.pairAId) {
      const aWon =
        h2h.pairAId === a.pairId ? h2h.scoreA! > h2h.scoreB! : h2h.scoreB! > h2h.scoreA!
      return aWon ? -1 : 1
    }
    return 0
  })
}

export function propagateBracket(
  matches: TournamentMatch[],
  groups: Record<GroupId, string[]>
): TournamentMatch[] {
  let result = [...matches]

  const update = (id: string, pairAId: string | null, pairBId: string | null) => {
    result = result.map((m) => (m.id === id ? { ...m, pairAId, pairBId } : m))
  }
  const find = (id: string): TournamentMatch => {
    const m = result.find((match) => match.id === id)
    if (!m) throw new Error(`Match "${id}" not found`)
    return m
  }

  const standings: Record<GroupId, StandingRow[]> = {
    A: computeGroupStandings('A', groups.A, result),
    B: computeGroupStandings('B', groups.B, result),
    C: computeGroupStandings('C', groups.C, result),
    D: computeGroupStandings('D', groups.D, result),
  }

  const [qf1, qf2, qf3, qf4] = QF_IDS
  const [sf1, sf2] = SF_IDS

  // QF seeding: A1 vs B2, C2 vs D1, C1 vs D2, A2 vs B1
  update(qf1, standings.A[0]?.pairId ?? null, standings.B[1]?.pairId ?? null)
  update(qf2, standings.C[1]?.pairId ?? null, standings.D[0]?.pairId ?? null)
  update(qf3, standings.C[0]?.pairId ?? null, standings.D[1]?.pairId ?? null)
  update(qf4, standings.A[1]?.pairId ?? null, standings.B[0]?.pairId ?? null)

  update(sf1, getMatchWinner(find(qf1)), getMatchWinner(find(qf2)))
  update(sf2, getMatchWinner(find(qf3)), getMatchWinner(find(qf4)))

  update(FINAL_ID, getMatchWinner(find(sf1)), getMatchWinner(find(sf2)))
  update(THIRD_PLACE_ID, getMatchLoser(find(sf1)), getMatchLoser(find(sf2)))

  return result
}

export function assignGroupPics(
  pairs: TournamentPair[],
  groups: Record<GroupId, string[]>,
  matches: TournamentMatch[]
): TournamentMatch[] {
  const pairNameMap = new Map(pairs.map((p) => [p.id, p.name]))

  const MAX_PIC_ATTEMPTS = 20
  const result = matches.map((match) => ({ ...match }))

  for (const groupId of GROUP_IDS) {
    // Build pairId -> individual names
    const pairNames = new Map<string, string[]>()
    for (const pairId of groups[groupId]) {
      const name = pairNameMap.get(pairId) ?? pairId
      pairNames.set(pairId, name.includes(' & ') ? name.split(' & ') : [name])
    }

    // Pool of all individual names in the group
    const pool: string[] = []
    for (const names of pairNames.values()) pool.push(...names)

    const groupMatches = result.filter((match) => match.phase === 'group' && match.groupId === groupId)

    let assigned = false
    for (let attempt = 0; attempt < MAX_PIC_ATTEMPTS; attempt++) {
      const shuffled = shuffle(pool)
      pool.length = 0
      pool.push(...shuffled)
      const used = new Set<string>()
      const assignments: Array<{ match: TournamentMatch; pic: string }> = []
      let ok = true
      for (const match of groupMatches) {
        const playing = new Set<string>([
          ...(match.pairAId ? (pairNames.get(match.pairAId) ?? []) : []),
          ...(match.pairBId ? (pairNames.get(match.pairBId) ?? []) : []),
        ])
        const pic = pool.find((name) => !playing.has(name) && !used.has(name))
        if (!pic) {
          ok = false
          break
        }
        assignments.push({ match, pic })
        used.add(pic)
      }
      if (ok) {
        for (const { match, pic } of assignments) match.picName = pic
        assigned = true
        break
      }
    }
    if (!assigned) {
      console.warn(`assignGroupPics: could not assign all PICs for group ${groupId}`)
    }
  }

  return result
}
