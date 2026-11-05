import { useQuery } from '@tanstack/react-query'
import { listPlayers, getPlayerStats } from './endpoints'
import type { PlayerSummary, PlayerStats } from './types'
import { communityQueryKey } from './keys'

export function useListPlayers() {
  return useQuery<PlayerSummary[]>({
    queryKey: communityQueryKey('players'),
    queryFn: ({ signal }) => listPlayers(signal),
  })
}

export function useGetPlayerStats(name: string | undefined) {
  return useQuery<PlayerStats>({
    queryKey: communityQueryKey('player', name),
    queryFn: ({ signal }) => getPlayerStats(decodeURIComponent(name!), signal),
    enabled: !!name,
  })
}
