// Client mirror of modules/tournament/domain/team.nim and team_draw.nim.
// Every constant and comparator here matches the domain one-for-one; the page
// only renders what these functions compute.

import type {
  TeamClass,
  TeamInfo,
  TeamMatch,
  TeamPartai,
  TeamPhase,
  TeamSnapshot,
} from '../types'

/** Six canonical team names; a tournament uses each exactly once. */
export const TEAM_NAMES = [
  'RED RAPTORS',
  'WHITE FURY',
  'BLUE WAVES',
  'PURPLE PHANTOMS',
  'GREEN GROVE',
  'PINK SPECTRE',
] as const

export const TEAM_CLASSES: readonly TeamClass[] = ['A+', 'A', 'B+', 'B', 'C+', 'C']

/** Partai 0 is C+/C, partai 1 is A+/A, partai 2 is B+/B. */
export const PARTAI_CLASSES: readonly (readonly [TeamClass, TeamClass])[] = [
  ['C+', 'C'],
  ['A+', 'A'],
  ['B+', 'B'],
]

export type GroupDrawSlot = {
  /** Canonical slot index (0..5) that plays team A. */
  teamA: number
  teamB: number
  court: string
}

/** Fixed draw over slot indices: 3 sessions x 3 courts, every team plays
 * three times and no pairing repeats. */
export const GROUP_DRAW_SLOTS: readonly GroupDrawSlot[] = [
  { teamA: 0, teamB: 1, court: 'Court 12' },
  { teamA: 2, teamB: 3, court: 'Court 13' },
  { teamA: 4, teamB: 5, court: 'Court 14' },
  { teamA: 3, teamB: 5, court: 'Court 12' },
  { teamA: 0, teamB: 2, court: 'Court 13' },
  { teamA: 1, teamB: 4, court: 'Court 14' },
  { teamA: 2, teamB: 4, court: 'Court 12' },
  { teamA: 1, teamB: 5, court: 'Court 13' },
  { teamA: 0, teamB: 3, court: 'Court 14' },
]

/** One court entry per partai; the draw puts all three on the same court. */
export const DEFAULT_TEAM_COURTS: readonly [string, string, string] = [
  'Court 12',
  'Court 13',
  'Court 14',
]

export const GROUP_TARGET = 30
export const FINAL_TARGET = 42

/** Rally target per phase: group 30, final 42. Scoring only, not a cap. */
export function targetScore(phase: TeamPhase): number {
  return phase === 'final' ? FINAL_TARGET : GROUP_TARGET
}

export function partaiClasses(
  index: number,
): readonly [TeamClass, TeamClass] | null {
  return index >= 0 && index < PARTAI_CLASSES.length ? PARTAI_CLASSES[index] : null
}

/** True when a player of `cls` plays partai number `index`. */
export function classInPartai(index: number, cls: TeamClass): boolean {
  const pair = partaiClasses(index)
  return pair !== null && (pair[0] === cls || pair[1] === cls)
}

export function emptyPartai(): TeamPartai {
  return { scoreA: null, scoreB: null }
}

function emptyPartaiList(): TeamPartai[] {
  return [emptyPartai(), emptyPartai(), emptyPartai()]
}

/** The client "draw" action: nine unscored group matches, ids g-1..g-9. */
export function drawGroupMatches(teamIds: readonly string[]): TeamMatch[] {
  if (teamIds.length !== 6) {
    throw new Error('a group draw needs exactly 6 teams')
  }
  return GROUP_DRAW_SLOTS.map((slot, index) => ({
    id: `g-${index + 1}`,
    phase: 'group',
    teamA: teamIds[slot.teamA],
    teamB: teamIds[slot.teamB],
    partai: emptyPartaiList(),
    courts: [slot.court, slot.court, slot.court],
  }))
}

/** The final is a single team-match on Court 12 with three unplayed partai. */
export function finalMatch(teamA: string, teamB: string): TeamMatch {
  const court = DEFAULT_TEAM_COURTS[0]
  return {
    id: 'final',
    phase: 'final',
    teamA,
    teamB,
    partai: emptyPartaiList(),
    courts: [court, court, court],
  }
}

/** What `patchTeamMatch` accepts: either field may be omitted, not both. */
export type TeamMatchPatch = {
  courts?: [string, string, string]
  partai?: TeamPartai[]
}

export type TeamOutcome = {
  winsA: number
  winsB: number
  complete: boolean
}

/** Partai won by each side; complete only when every partai has both scores. */
export function teamMatchOutcome(match: TeamMatch): TeamOutcome {
  const outcome: TeamOutcome = { winsA: 0, winsB: 0, complete: true }
  for (const partai of match.partai) {
    if (partai.scoreA === null || partai.scoreB === null) {
      outcome.complete = false
      continue
    }
    if (partai.scoreA > partai.scoreB) outcome.winsA += 1
    else if (partai.scoreB > partai.scoreA) outcome.winsB += 1
  }
  return outcome
}

/** 3-0 = 3, 2-1 = 2, 1-2 = 1, 0-3 = 0. */
export function teamMatchPoints(wins: number, losses: number): number {
  if (wins === 3) return 3
  if (wins === 2) return 2
  if (losses === 2) return 1
  return 0
}

export type TeamStanding = {
  teamId: string
  teamName: string
  /** Complete team-matches that counted. */
  played: number
  /** Partai won across team-matches (v1 `teamWins`), not team-match results. */
  wins: number
  losses: number
  points: number
  pointsFor: number
  pointsAgainst: number
}

/** Group standings. Undrawn or unfinished team-matches count for nothing.
 * The sort is stable, so a full tie keeps the teams' input order. */
export function computeStandings(
  teams: readonly TeamInfo[],
  matches: readonly TeamMatch[],
): TeamStanding[] {
  const rows = new Map<string, TeamStanding>()
  const order: string[] = []
  for (const team of teams) {
    rows.set(team.id, {
      teamId: team.id,
      teamName: team.name,
      played: 0,
      wins: 0,
      losses: 0,
      points: 0,
      pointsFor: 0,
      pointsAgainst: 0,
    })
    order.push(team.id)
  }

  for (const match of matches) {
    const outcome = teamMatchOutcome(match)
    if (!outcome.complete) continue
    const a = rows.get(match.teamA)
    const b = rows.get(match.teamB)
    if (a === undefined || b === undefined) continue
    a.played += 1
    b.played += 1
    a.wins += outcome.winsA
    a.losses += outcome.winsB
    b.wins += outcome.winsB
    b.losses += outcome.winsA
    a.points += teamMatchPoints(outcome.winsA, outcome.winsB)
    b.points += teamMatchPoints(outcome.winsB, outcome.winsA)
    for (const partai of match.partai) {
      if (partai.scoreA === null || partai.scoreB === null) continue
      a.pointsFor += partai.scoreA
      a.pointsAgainst += partai.scoreB
      b.pointsFor += partai.scoreB
      b.pointsAgainst += partai.scoreA
    }
  }

  const standings = order.map((id) => rows.get(id) as TeamStanding)
  standings.sort(
    (x, y) =>
      y.points - x.points ||
      y.wins - y.losses - (x.wins - x.losses) ||
      y.pointsFor - y.pointsAgainst - (x.pointsFor - x.pointsAgainst),
  )
  return standings
}

/** Winner of the single final team-match once every partai is scored. */
export function champion(snapshot: TeamSnapshot): string | null {
  for (const match of snapshot.matches) {
    if (match.phase !== 'final') continue
    const outcome = teamMatchOutcome(match)
    if (!outcome.complete) return null
    return outcome.winsA > outcome.winsB ? match.teamA : match.teamB
  }
  return null
}

export function groupMatches(snapshot: TeamSnapshot): TeamMatch[] {
  return snapshot.matches.filter((match) => match.phase === 'group')
}

/** The group draw is either undrawn or the full nine; complete means every
 * partai carries both scores. */
export function isGroupComplete(snapshot: TeamSnapshot): boolean {
  const group = groupMatches(snapshot)
  return group.length === 9 && group.every((match) => teamMatchOutcome(match).complete)
}

export function teamsById(teams: readonly TeamInfo[]): Map<string, string> {
  return new Map(teams.map((team) => [team.id, team.name]))
}
