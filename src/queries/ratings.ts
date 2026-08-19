// src/queries/ratings.ts — hooks rating (plan RATINGS_FRONTEND_PLAN.md §6.3)
import { useQuery } from '@tanstack/react-query'
import { getRatingLeaderboard, getRatingPlayer } from './endpoints'
import type { RatingPlayer, RatingLeaderboardRow } from './endpoints'

export function useRatingLeaderboard(active: boolean, limit: number, offset: number) {
  return useQuery<{ total: number; rows: RatingLeaderboardRow[] }>({
    queryKey: ['ratings', active, limit, offset],
    queryFn: () => getRatingLeaderboard(active, limit, offset),
    staleTime: 1000 * 60,
  })
}

export function useRatingPlayer(playerId: string | undefined) {
  return useQuery<RatingPlayer>({
    queryKey: ['ratings-player', playerId],
    queryFn: () => getRatingPlayer(playerId!),
    enabled: !!playerId,
    staleTime: 1000 * 60,
  })
}
