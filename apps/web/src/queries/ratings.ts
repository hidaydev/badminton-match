// src/queries/ratings.ts — hooks rating (plan RATINGS_FRONTEND_PLAN.md §6.3)
import { useQuery } from '@tanstack/react-query'
import { getRatingLeaderboard, getRatingPlayer, getRatingSeasons, getSeasonStandings, request } from './endpoints'
import type { RatingPlayer, RatingLeaderboardRow, RatingSeason, SeasonStandingRow } from './endpoints'

export function useRatingLeaderboard(active: boolean, limit: number, offset: number) {
  return useQuery<{ total: number; rows: RatingLeaderboardRow[] }>({
    queryKey: ['ratings', active, limit, offset],
    queryFn: ({ signal }) => getRatingLeaderboard(active, limit, offset, signal),
    staleTime: 1000 * 60,
  })
}

export function useRatingPlayer(playerId: string | undefined) {
  return useQuery<RatingPlayer>({
    queryKey: ['ratings-player', playerId],
    queryFn: ({ signal }) => getRatingPlayer(playerId!, signal),
    enabled: !!playerId,
    staleTime: 1000 * 60,
  })
}

export function useRatingSeasons() {
  return useQuery<RatingSeason[]>({
    queryKey: ['ratings-seasons'],
    queryFn: ({ signal }) => getRatingSeasons(signal),
    staleTime: 1000 * 60 * 5,
  })
}

export function useSeasonStandings(seasonId: string | null) {
  return useQuery<SeasonStandingRow[]>({
    queryKey: ['ratings-season-standings', seasonId],
    queryFn: ({ signal }) => getSeasonStandings(seasonId!, signal),
    enabled: !!seasonId,
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
    queryKey: ['ratings-sources'],
    queryFn: async ({ signal }) => {
      const data = await request<{ sources: RatingSourceRow[] }>('GET', '/ratings/sources', undefined, signal)
      return data?.sources ?? []
    },
  })
}
