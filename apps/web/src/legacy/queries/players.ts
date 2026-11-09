import { useQuery } from '@tanstack/react-query'
import { listPlayers, getPlayerStatsRaw, knownPlayerId, toPlayerStats } from './endpoints'
import type { V2PlayerStats } from './endpoints'
import type { PlayerSummary, PlayerStats } from './types'
import { communityQueryKey } from './keys'

export function useListPlayers() {
  return useQuery<PlayerSummary[]>({
    queryKey: communityQueryKey('players'),
    queryFn: ({ signal }) => listPlayers(signal),
  })
}

/**
 * One stats read per player, keyed by the id: the rating card and the career
 * card both mount it on the same page, and a second key would make the same
 * `/players/{id}/stats` request twice.
 */
export function useGetPlayerStats(nameOrId: string | undefined) {
  const playerId =
    nameOrId === undefined || nameOrId === ''
      ? null
      : knownPlayerId(nameOrId) ?? nameOrId
  // `enabled` keeps the query from running without an id; the empty string is
  // the inert value here so the reader does not have to trust an assertion.
  const id = playerId ?? ''

  return useQuery<V2PlayerStats, Error, PlayerStats>({
    queryKey: communityQueryKey('playerStats', id),
    queryFn: ({ signal }) => getPlayerStatsRaw(id, signal),
    select: toPlayerStats,
    enabled: playerId !== null,
    staleTime: 1000 * 60,
  })
}