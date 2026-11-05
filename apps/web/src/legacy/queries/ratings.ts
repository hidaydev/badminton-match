// src/queries/ratings.ts — hooks rating (plan RATINGS_FRONTEND_PLAN.md §6.3)
import { useQuery } from '@tanstack/react-query'
import { getRatingPlayer, getPlayerAchievements, getRankings, getPlayerRankPoints, request, communityApiPath } from './endpoints'
import type { RatingPlayer, AchievementRow, RankPointsBoard, PlayerRankPoints } from './endpoints'
import { communityQueryKey } from './keys'

// useRankings — papan poin publik (window bergulir, N entri terbaik).
export function useRankings(limit = 200, minSessions?: number) {
  return useQuery<RankPointsBoard>({
    queryKey: communityQueryKey('rankings', limit, minSessions),
    queryFn: ({ signal }) => getRankings(limit, minSessions, signal),
    staleTime: 1000 * 60,
  })
}

// usePlayerRankPoints — poin ranking satu pemain (halaman detail publik).
export function usePlayerRankPoints(playerId: string | undefined) {
  return useQuery<PlayerRankPoints>({
    queryKey: communityQueryKey('rankings', 'player', playerId),
    queryFn: ({ signal }) => getPlayerRankPoints(playerId!, signal),
    enabled: !!playerId,
    staleTime: 1000 * 60,
  })
}

export function useRatingPlayer(playerId: string | undefined) {
  return useQuery<RatingPlayer>({
    queryKey: communityQueryKey('ratings', 'player', playerId),
    queryFn: ({ signal }) => getRatingPlayer(playerId!, signal),
    enabled: !!playerId,
    staleTime: 1000 * 60,
  })
}

export function useRatingPlayerAchievements(playerId: string | undefined) {
  return useQuery<AchievementRow[]>({
    queryKey: communityQueryKey('ratings', 'player', playerId, 'achievements'),
    queryFn: ({ signal }) => getPlayerAchievements(playerId!, signal),
    enabled: !!playerId,
    staleTime: 1000 * 60,
  })
}

// RatingSourceRow — the admin row is grouped from the v2 event list.
export interface RatingSourceRow {
  source_id: string
  source_name: string
  source_kind: string
  finalized: boolean
  ingested_at: string
  event_count: number
}

type V2RatingEvent = {
  id: string
  type: string
  date: string
  sourceId: string
  deltas: number
  finalized: boolean
  finalizedAt: string | null
}

export function useRatingSources() {
  return useQuery<RatingSourceRow[]>({
    queryKey: communityQueryKey('ratings', 'sources'),
    queryFn: async ({ signal }) => {
      const data = await request<{ items: V2RatingEvent[] }>(
        'GET',
        communityApiPath('/rating-sources'),
        undefined,
        signal,
      )
      const grouped = new Map<string, RatingSourceRow>()
      for (const event of data?.items ?? []) {
        const sourceId = event.sourceId || event.id
        const current = grouped.get(sourceId)
        if (current === undefined) {
          grouped.set(sourceId, {
            source_id: sourceId,
            source_name: `${event.type === 'tournament' ? 'Tournament' : 'Session'} · ${event.date}`,
            source_kind: event.type,
            finalized: event.finalized,
            ingested_at: event.finalizedAt ?? '',
            event_count: event.deltas,
          })
        } else {
          current.event_count += event.deltas
          current.finalized = current.finalized || event.finalized
        }
      }
      return [...grouped.values()]
    },
  })
}
