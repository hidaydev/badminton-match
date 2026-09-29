// src/queries/ratings.ts — hooks rating (plan RATINGS_FRONTEND_PLAN.md §6.3)
import { useQuery } from '@tanstack/react-query'
import { getRatingPlayer, getPlayerAchievements, getRankings, getPlayerRankPoints, request } from './endpoints'
import type { RatingPlayer, AchievementRow, RankPointsBoard, PlayerRankPoints } from './endpoints'

// useRankings — papan poin publik (window bergulir, N entri terbaik).
export function useRankings(limit = 200) {
  return useQuery<RankPointsBoard>({
    queryKey: ['rankings', limit],
    queryFn: ({ signal }) => getRankings(limit, signal),
    staleTime: 1000 * 60,
  })
}

// usePlayerRankPoints — poin ranking satu pemain (halaman detail publik).
export function usePlayerRankPoints(playerId: string | undefined) {
  return useQuery<PlayerRankPoints>({
    queryKey: ['rankings', 'player', playerId],
    queryFn: ({ signal }) => getPlayerRankPoints(playerId!, signal),
    enabled: !!playerId,
    staleTime: 1000 * 60,
  })
}

export function useRatingPlayer(playerId: string | undefined) {
  return useQuery<RatingPlayer>({
    queryKey: ['ratings', 'player', playerId],
    queryFn: ({ signal }) => getRatingPlayer(playerId!, signal),
    enabled: !!playerId,
    staleTime: 1000 * 60,
  })
}

export function useRatingPlayerAchievements(playerId: string | undefined) {
  return useQuery<AchievementRow[]>({
    queryKey: ['ratings', 'player', playerId, 'achievements'],
    queryFn: ({ signal }) => getPlayerAchievements(playerId!, signal),
    enabled: !!playerId,
    staleTime: 1000 * 60,
  })
}

// RatingSourceRow — dari GET /ratings/sources
export interface RatingSourceRow {
  source_id: string
  source_name: string // resolved name (session title or tournament name)
  source_kind: string
  finalized: boolean
  ingested_at: string
  event_count: number
}

export function useRatingSources() {
  return useQuery<RatingSourceRow[]>({
    queryKey: ['ratings', 'sources'],
    queryFn: async ({ signal }) => {
      const data = await request<{ sources: RatingSourceRow[] }>('GET', '/ratings/sources', undefined, signal)
      return data?.sources ?? []
    },
  })
}
