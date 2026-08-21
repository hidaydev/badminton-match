// src/utils/teamTournament.ts
// Format tournament TIM: 6 tim × 6 pemain (6 kelas), 3 partai ganda per
// team-match, rally 30 (grup) / 42 (final), top-2 → final.
// Mirror kontrak backend (majadu-api/internal/domain/team_tournament.go).

import { shuffle } from './array'
import type { TournamentSnapshot } from './tournament'

export type TeamClass = 'A+' | 'A' | 'B+' | 'B' | 'C+' | 'C'
export type TeamPhase = 'group' | 'final'

export interface TeamPlayer {
  name: string
  cls: TeamClass
}

export interface TeamInfo {
  id: string
  name: string
  players: TeamPlayer[]
}

export interface TeamPartai {
  scoreA: number | null
  scoreB: number | null
}

export interface TeamMatch {
  id: string
  phase: TeamPhase
  teamA: string
  teamB: string
  partai: TeamPartai[]
  courts: [string, string, string] // 3 court names, one per partai
}

export interface TeamTournamentSnapshot {
  version?: number
  format: 'team'
  name: string
  date: string
  teams: TeamInfo[]
  matches: TeamMatch[]
}

/** Union snapshot — discriminated oleh `format`. */
export type AnyTournamentSnapshot = TournamentSnapshot | TeamTournamentSnapshot

/** 6 kelas valid. */
export const TEAM_CLASSES: TeamClass[] = ['A+', 'A', 'B+', 'B', 'C+', 'C']

/** Kelas pair per partai (urutan tetap): 0=C+ C · 1=A+ A · 2=B+ B. */
export const PARTAI_CLASSES: [TeamClass, TeamClass][] = [
  ['C+', 'C'],
  ['A+', 'A'],
  ['B+', 'B'],
]

/** Partai ke-i team A → id pemain kelas C+ (A+ / B+). */
export function partaiClassA(i: number): TeamClass {
  return PARTAI_CLASSES[i][0]
}

/** Partai ke-i team A → id pemain kelas C (A / B). */
export function partaiClassB(i: number): TeamClass {
  return PARTAI_CLASSES[i][1]
}

/** Skor target: grup 30, final 42. */
export function teamTarget(phase: TeamPhase): number {
  return phase === 'final' ? 42 : 30
}

// ── outcome & standings ────────────────────────────────────────────────────

export interface TeamOutcome {
  aWins: number
  bWins: number
  complete: boolean
}

/** Hitung partai yang dimenangkan tiap sisi. complete = semua 3 partai ada skor. */
export function teamMatchOutcome(match: TeamMatch): TeamOutcome {
  let aWins = 0
  let bWins = 0
  let complete = true
  for (const pt of match.partai) {
    // == null: null ATAU undefined (partai kosong) dianggap belum dimainkan
    if (pt.scoreA == null || pt.scoreB == null) {
      complete = false
      continue
    }
    if (pt.scoreA > pt.scoreB) aWins++
    else if (pt.scoreB > pt.scoreA) bWins++
  }
  return { aWins, bWins, complete }
}

export interface TeamStandingRow {
  teamId: string
  teamName: string
  played: number
  teamWins: number
  teamLosses: number
  points: number
  pointsFor: number
  pointsAgainst: number
}

/** Poin: menang 3-0 = 3 · 2-1 = 2 · kalah 1-2 = 1 · 0-3 = 0. */
export function teamMatchPoints(wins: number, losses: number): number {
  if (wins === 3) return 3
  if (wins === 2) return 2
  if (losses === 2) return 1
  return 0
}

/**
 * Klasemen grup:
 * 1. poin tertinggi
 * 2. selisih menang-kalah (teamWins - teamLosses) tertinggi
 * 3. selisih poin agregat (pointsFor - pointsAgainst) tertinggi
 */
export function computeTeamStandings(teams: TeamInfo[], matches: TeamMatch[]): TeamStandingRow[] {
  const rows: Record<string, TeamStandingRow> = {}
  for (const t of teams) {
    rows[t.id] = {
      teamId: t.id, teamName: t.name,
      played: 0, teamWins: 0, teamLosses: 0,
      points: 0, pointsFor: 0, pointsAgainst: 0,
    }
  }
  for (const m of matches) {
    const out = teamMatchOutcome(m)
    if (!out.complete) continue
    const a = rows[m.teamA]
    const b = rows[m.teamB]
    if (!a || !b) continue
    a.played++
    b.played++
    a.teamWins += out.aWins
    a.teamLosses += out.bWins
    b.teamWins += out.bWins
    b.teamLosses += out.aWins
    a.points += teamMatchPoints(out.aWins, out.bWins)
    b.points += teamMatchPoints(out.bWins, out.aWins)
    for (const pt of m.partai) {
      if (pt.scoreA === null || pt.scoreB === null) continue
      a.pointsFor += pt.scoreA
      a.pointsAgainst += pt.scoreB
      b.pointsFor += pt.scoreB
      b.pointsAgainst += pt.scoreA
    }
  }
  return Object.values(rows).sort((x, y) => {
    if (y.points !== x.points) return y.points - x.points
    const xDiff = x.teamWins - x.teamLosses
    const yDiff = y.teamWins - y.teamLosses
    if (yDiff !== xDiff) return yDiff - xDiff
    return (y.pointsFor - y.pointsAgainst) - (x.pointsFor - x.pointsAgainst)
  })
}

// ── undian grup ─────────────────────────────────────────────────────────────

/**
 * Jadwal 9 team-match seimbang: tiap tim tepat 3×, tanpa ulangan lawan.
 * Urutan tim diacak ("undian" hari-H). Ids = [t1..t6].
 */
export function generateTeamDraw(teamIds: string[]): [string, string][] {
  if (teamIds.length !== 6) throw new Error('generateTeamDraw membutuhkan tepat 6 tim')
  const shuffled = shuffle(teamIds)
  const schedule: [number, number][] = [
    [0, 1], [2, 3], [4, 5],
    [0, 2], [1, 4], [3, 5],
    [0, 3], [1, 5], [2, 4],
  ]
  return schedule.map(([a, b]) => [shuffled[a], shuffled[b]])
}
