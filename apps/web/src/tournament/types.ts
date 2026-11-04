// Snapshot types mirror the tournament API exactly. `id` and `version` are
// present on a created/replaced snapshot (and on reads as version); the child
// match id is the canonical key the server exposes (group-A-0, qf-1, g-1…).

export type GroupId = 'A' | 'B' | 'C' | 'D'
export type ClassicPhase = 'group' | 'qf' | 'sf' | '3rd' | 'final'
export type TeamClass = 'A+' | 'A' | 'B+' | 'B' | 'C+' | 'C'
export type TeamPhase = 'group' | 'final'
export type Format = 'classic' | 'team'

export type Pair = {
  id: string
  name: string
}

export type ClassicMatch = {
  id: string
  phase: ClassicPhase
  groupId: GroupId | null
  pairAId: string | null
  pairBId: string | null
  scoreA: number | null
  scoreB: number | null
}

export type ClassicSnapshot = {
  id?: string
  version?: number
  format?: 'classic'
  name: string
  date: string
  pairs: Pair[]
  groups: Record<GroupId, string[]>
  matches: ClassicMatch[]
}

export type TeamPlayer = {
  name: string
  cls: TeamClass
}

export type TeamInfo = {
  id: string
  name: string
  players: TeamPlayer[]
}

export type TeamPartai = {
  scoreA: number | null
  scoreB: number | null
}

export type TeamMatch = {
  id: string
  phase: TeamPhase
  teamA: string
  teamB: string
  partai: TeamPartai[]
  courts: [string, string, string]
}

export type TeamSnapshot = {
  id?: string
  version?: number
  format: 'team'
  name: string
  date: string
  teams: TeamInfo[]
  matches: TeamMatch[]
}

export type Tournament = ClassicSnapshot | TeamSnapshot

/** One row of `GET /c/{slug}/tournaments`. */
export type TournamentMeta = {
  id: string
  name: string
  date: string
  format: Format
  status: string
  version: number
}

export function isTeam(snapshot: Tournament): snapshot is TeamSnapshot {
  return snapshot.format === 'team'
}
