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
  playerId?: string
  gamesPlayed: number
  wins: number
  losses: number
  pointsFor: number
  pointsAgainst: number
  sessions: { id: string; date: string; title: string; absent?: boolean }[]
  topPartners: { name: string; count: number; wins: number; losses: number }[]
  topOpponents: { name: string; count: number; wins: number; losses: number }[]
  // Tournament career stats — dihitung dari tabel tournament normalized (V2).
  tournamentStats: {
    gamesPlayed: number
    wins: number
    losses: number
    tournaments: { name: string; date: string; games: number; wins: number; losses: number }[]
    topPartners: { name: string; count: number; wins: number }[]
    topOpponents: { name: string; count: number; wins: number }[]
  }
}
