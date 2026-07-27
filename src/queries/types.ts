export type { CloudSnapshot, PlayerSummary } from '../types'
export type { TournamentSnapshot } from '../utils/tournament'

export interface SessionMeta {
  id: string
  title: string
  date: string
  playerCount: number
  totalGames: number
  locked: boolean
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
