import type { SessionConfig, Player, FixMatch, ScheduleSlot, GameScore } from '../store'
export type { TournamentSnapshot } from '../utils/tournament'

export interface CloudSnapshot {
  session: SessionConfig
  players: Player[]
  fixMatches: FixMatch[]
  schedule: ScheduleSlot[]
  playedGames: string[]
  gameScores: Record<string, GameScore>
  absentPlayers?: string[]
}

export interface SessionMeta {
  id: string
  title: string
  date: string
  playerCount: number
  totalGames: number
}

export interface PlayerSummary {
  name: string
  gender: 'M' | 'F'
  tier: 1 | 2 | 3 | 4
}

export interface PlayerStats {
  name: string
  gamesPlayed: number
  wins: number
  losses: number
  pointsFor: number
  pointsAgainst: number
  sessions: { id: string; date: string; title: string; absent?: boolean }[]
  topPartners: { name: string; count: number; wins: number; losses: number }[]
  topOpponents: { name: string; count: number; wins: number; losses: number }[]
}
