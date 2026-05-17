export type GroupId = 'A' | 'B' | 'C' | 'D'
export type MatchPhase = 'group' | 'qf' | 'sf' | '3rd' | 'final'

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

export interface StandingRow {
  pairId: string
  wins: number
  losses: number
  pointFor: number
  pointAgainst: number
  pointDiff: number
}

export const GROUP_COURTS: Record<GroupId, number> = { A: 9, B: 10, C: 11, D: 12 }

export interface TournamentSnapshot {
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
    ko('qf-1', 'qf'), ko('qf-2', 'qf'), ko('qf-3', 'qf'), ko('qf-4', 'qf'),
    ko('sf-1', 'sf'), ko('sf-2', 'sf'),
    ko('3rd-1', '3rd'),
    ko('final-1', 'final'),
  ]
}

export function getMatchWinner(match: TournamentMatch): string | null {
  if (match.scoreA === null || match.scoreB === null || !match.pairAId || !match.pairBId) return null
  return match.scoreA > match.scoreB ? match.pairAId : match.pairBId
}

export function getMatchLoser(match: TournamentMatch): string | null {
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
    rows[id] = { pairId: id, wins: 0, losses: 0, pointFor: 0, pointAgainst: 0, pointDiff: 0 }
  }

  for (const m of groupMatches) {
    if (m.scoreA === null || m.scoreB === null || !m.pairAId || !m.pairBId) continue
    const a = rows[m.pairAId]
    const b = rows[m.pairBId]
    if (!a || !b) continue
    a.pointFor += m.scoreA; a.pointAgainst += m.scoreB
    b.pointFor += m.scoreB; b.pointAgainst += m.scoreA
    if (m.scoreA > m.scoreB) { a.wins++; b.losses++ } else { b.wins++; a.losses++ }
  }

  for (const row of Object.values(rows)) row.pointDiff = row.pointFor - row.pointAgainst

  return Object.values(rows).sort((a, b) => {
    if (b.wins !== a.wins) return b.wins - a.wins
    if (b.pointDiff !== a.pointDiff) return b.pointDiff - a.pointDiff
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
  groups: Record<GroupId, string[]>,
  _pairs: TournamentPair[]
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

  const s: Record<GroupId, StandingRow[]> = {
    A: computeGroupStandings('A', groups.A, result),
    B: computeGroupStandings('B', groups.B, result),
    C: computeGroupStandings('C', groups.C, result),
    D: computeGroupStandings('D', groups.D, result),
  }

  // QF seeding: A1 vs B2, C2 vs D1, C1 vs D2, A2 vs B1
  update('qf-1', s.A[0]?.pairId ?? null, s.B[1]?.pairId ?? null)
  update('qf-2', s.C[1]?.pairId ?? null, s.D[0]?.pairId ?? null)
  update('qf-3', s.C[0]?.pairId ?? null, s.D[1]?.pairId ?? null)
  update('qf-4', s.A[1]?.pairId ?? null, s.B[0]?.pairId ?? null)

  update('sf-1', getMatchWinner(find('qf-1')), getMatchWinner(find('qf-2')))
  update('sf-2', getMatchWinner(find('qf-3')), getMatchWinner(find('qf-4')))

  update('final-1', getMatchWinner(find('sf-1')), getMatchWinner(find('sf-2')))
  update('3rd-1',   getMatchLoser(find('sf-1')),  getMatchLoser(find('sf-2')))

  return result
}

export function assignGroupPics(
  pairs: TournamentPair[],
  groups: Record<GroupId, string[]>,
  matches: TournamentMatch[]
): TournamentMatch[] {
  const pairNameMap = new Map(pairs.map((p) => [p.id, p.name]))

  const result = matches.map((m) => ({ ...m }))

  for (const g of ['A', 'B', 'C', 'D'] as GroupId[]) {
    // Build pairId -> individual names
    const pairNames = new Map<string, string[]>()
    for (const pairId of groups[g]) {
      const name = pairNameMap.get(pairId) ?? pairId
      pairNames.set(pairId, name.includes(' & ') ? name.split(' & ') : [name])
    }

    // Pool of all 8 names in the group, shuffled
    const pool: string[] = []
    for (const names of pairNames.values()) pool.push(...names)
    for (let i = pool.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [pool[i], pool[j]] = [pool[j], pool[i]]
    }

    const used = new Set<string>()
    const groupMatches = result.filter((m) => m.phase === 'group' && m.groupId === g)

    for (const m of groupMatches) {
      const playing = new Set<string>([
        ...(m.pairAId ? (pairNames.get(m.pairAId) ?? []) : []),
        ...(m.pairBId ? (pairNames.get(m.pairBId) ?? []) : []),
      ])
      const pic = pool.find((name) => !playing.has(name) && !used.has(name))
      if (pic) {
        m.picName = pic
        used.add(pic)
      }
    }
  }

  return result
}
