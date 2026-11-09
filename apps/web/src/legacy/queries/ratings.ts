// src/queries/ratings.ts — hooks rating (plan RATINGS_FRONTEND_PLAN.md §6.3)
import { useQuery } from '@tanstack/react-query'
import { getPlayerAchievements, getRankings, getPlayerRankPoints, getPlayerStatsRaw, request, communityApiPath, toRatingPlayer } from './endpoints'
import type { V2PlayerStats, RatingPlayer, AchievementRow, RankPointsBoard, PlayerRankPoints } from './endpoints'
import { communityQueryKey } from './keys'
import { collectPages } from '../../api/paged'
import type { RatingSource, RatingSourcePage } from '@majadu/web-client'

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
  // Same key as the career card: one `/players/{id}/stats` read serves both.
  return useQuery<V2PlayerStats, Error, RatingPlayer>({
    queryKey: communityQueryKey('playerStats', playerId ?? ''),
    queryFn: ({ signal }) => getPlayerStatsRaw(playerId!, signal),
    select: toRatingPlayer,
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
  /** The rating event behind the source; null when there is nothing to delete. */
  event_id: string | null
}

export function useRatingSources() {
  return useQuery<RatingSourceRow[]>({
    queryKey: communityQueryKey('ratings', 'sources'),
    queryFn: async ({ signal }) => {
      const events = await collectPages<RatingSource>((offset, limit) =>
        request<RatingSourcePage>(
          'GET',
          communityApiPath('/rating-sources') + `?limit=${limit}&offset=${offset}`,
          undefined,
          signal,
        ),
      )
      const grouped = new Map<string, RatingSourceRow>()
      for (const event of events) {
        const sourceId = event.sourceId || event.id
        // One event per source. A tournament that was never ingested still gets
        // a row, but it reports the tournament id as both ids and has no event
        // to delete.
        const eventId = event.id === sourceId ? null : event.id
        const current = grouped.get(sourceId)
        if (current === undefined) {
          grouped.set(sourceId, {
            source_id: sourceId,
            source_name: `${event.type === 'tournament' ? 'Tournament' : 'Session'} · ${event.date}`,
            source_kind: event.type,
            finalized: event.finalized,
            ingested_at: event.finalizedAt ?? '',
            event_count: event.deltas,
            event_id: eventId,
          })
        } else {
          current.event_count += event.deltas
          current.finalized = current.finalized || event.finalized
          current.event_id = current.event_id ?? eventId
        }
      }
      return [...grouped.values()]
    },
  })
}
