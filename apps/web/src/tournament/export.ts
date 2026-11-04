// Maps a tournament snapshot onto the canvas module's row inputs.
//
// The export page must not re-derive standings: the classic and team helpers
// are the same ones the editor uses, so the image and the page can never
// disagree. Everything here is pure so it can be tested without a canvas.

import type {
  BracketRowInput,
  GroupRowInput,
  StandingsRow,
  TeamPartaiRowInput,
} from '../utils/canvas'
import { computeGroupStandings } from './classic/draw'
import { computeStandings, PARTAI_CLASSES, teamMatchOutcome } from './team/rules'
import type {
  ClassicPhase,
  ClassicSnapshot,
  GroupId,
  TeamInfo,
  TeamSnapshot,
} from './types'

export type BracketPhase = Exclude<ClassicPhase, 'group'>

export type TeamFinalExport = {
  teamAName: string
  teamBName: string
  teamAWins: number
  teamBWins: number
  partai: TeamPartaiRowInput[]
}

function pairNames(snapshot: ClassicSnapshot): Map<string, string> {
  return new Map(snapshot.pairs.map((pair) => [pair.id, pair.name]))
}

function nameOf(names: Map<string, string>, pairId: string | null): string {
  if (pairId === null) return ''
  return names.get(pairId) ?? pairId
}

/** One classic group, in the order the group table already shows. */
export function classicGroupRows(
  snapshot: ClassicSnapshot,
  groupId: GroupId,
): GroupRowInput[] {
  const names = pairNames(snapshot)
  return computeGroupStandings(
    groupId,
    snapshot.groups[groupId] ?? [],
    snapshot.matches,
  ).map((row) => ({
    name: names.get(row.pairId) ?? row.pairId,
    wins: row.wins,
    losses: row.losses,
    diff: row.diff,
  }))
}

const PHASE_LABEL: Record<BracketPhase, string> = {
  qf: 'QF',
  sf: 'SF',
  '3rd': '3RD',
  final: 'FINAL',
}

/** The matches of one knockout round, with the pair names resolved. */
export function classicBracketRows(
  snapshot: ClassicSnapshot,
  phase: BracketPhase,
): BracketRowInput[] {
  const names = pairNames(snapshot)
  return snapshot.matches
    .filter((match) => match.phase === phase)
    .map((match, index) => ({
      label:
        phase === 'final' || phase === '3rd'
          ? PHASE_LABEL[phase]
          : `${PHASE_LABEL[phase]} ${index + 1}`,
      nameA: nameOf(names, match.pairAId),
      nameB: nameOf(names, match.pairBId),
      scoreA: match.scoreA,
      scoreB: match.scoreB,
    }))
}

/** Team group table, using the same comparator as the editor. */
export function teamStandingRows(snapshot: TeamSnapshot): StandingsRow[] {
  const group = snapshot.matches.filter((match) => match.phase === 'group')
  return computeStandings(snapshot.teams, group).map((row) => ({
    name: row.teamName,
    wins: row.wins,
    losses: row.losses,
    diff: row.pointsFor - row.pointsAgainst,
    points: row.points,
  }))
}

function playerOfClass(team: TeamInfo, cls: string): string {
  return team.players.find((player) => player.cls === cls)?.name ?? ''
}

/** The final team-match, or `null` while it has not been created yet. */
export function teamFinalExport(snapshot: TeamSnapshot): TeamFinalExport | null {
  const match = snapshot.matches.find((candidate) => candidate.phase === 'final')
  if (match === undefined) return null
  const teams = new Map(snapshot.teams.map((team) => [team.id, team]))
  const teamA = teams.get(match.teamA)
  const teamB = teams.get(match.teamB)
  if (teamA === undefined || teamB === undefined) return null
  const outcome = teamMatchOutcome(match)
  return {
    teamAName: teamA.name,
    teamBName: teamB.name,
    teamAWins: outcome.winsA,
    teamBWins: outcome.winsB,
    partai: match.partai.map((partai, index) => {
      const classes = PARTAI_CLASSES[index] ?? null
      return {
        tier: classes === null ? `P${index + 1}` : `${classes[0]} / ${classes[1]}`,
        nameA: classes === null ? '' : playerOfClass(teamA, classes[0]),
        nameB: classes === null ? '' : playerOfClass(teamB, classes[1]),
        scoreA: partai.scoreA,
        scoreB: partai.scoreB,
      }
    }),
  }
}
