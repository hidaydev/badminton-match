import { request } from '../auth/api'

/** Player grades as the player domain stores them. */
export const TIERS: readonly string[] = ['D', 'D+', 'C', 'C+', 'B', 'B+', 'A', 'A+']

/** One row of `GET /c/{slug}/rankings`, in board order. */
export type RankingRow = {
  rank: number
  playerId: string
  name: string
  /** `null` when the player has no grade yet. */
  tier: string | null
  points: number
  games: number
  wins: number
  losses: number
}

export type RankingsBoard = {
  asOf: string
  items: RankingRow[]
}

/** `GET /c/{slug}/players/{playerId}/stats` */
export type PlayerStats = {
  playerId: string
  name: string
  tier: string | null
  gender: string | null
  points: number
  games: number
  wins: number
  losses: number
}

/** `GET /c/{slug}/players/{playerId}/achievements` */
export type Achievement = {
  key: string
  category: string
  threshold: number
  earnedAt: string
}

/** The board is capped by `rank.board_limit` on the server; never slice here. */
export function fetchRankings(slug: string, tier: string | null): Promise<RankingsBoard> {
  const query = tier === null ? '' : `?tier=${encodeURIComponent(tier)}`
  return request<RankingsBoard>(`/c/${encodeURIComponent(slug)}/rankings${query}`)
}

export function fetchPlayerRow(slug: string, playerId: string): Promise<RankingRow> {
  return request<RankingRow>(
    `/c/${encodeURIComponent(slug)}/rankings/${encodeURIComponent(playerId)}`,
  )
}

export function fetchPlayerStats(slug: string, playerId: string): Promise<PlayerStats> {
  return request<PlayerStats>(
    `/c/${encodeURIComponent(slug)}/players/${encodeURIComponent(playerId)}/stats`,
  )
}

export async function fetchPlayerAchievements(
  slug: string,
  playerId: string,
): Promise<Achievement[]> {
  const body = await request<{ items: Achievement[] }>(
    `/c/${encodeURIComponent(slug)}/players/${encodeURIComponent(playerId)}/achievements`,
  )
  return body.items
}
