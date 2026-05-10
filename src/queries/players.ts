import { useQuery } from '@tanstack/react-query'
import { listPlayers, getPlayerStats } from './endpoints'
import type { PlayerSummary, PlayerStats } from './types'

export function useListPlayers() {
  return useQuery<PlayerSummary[]>({
    queryKey: ['players'],
    queryFn: listPlayers,
  })
}

export function useGetPlayerStats(name: string | undefined) {
  return useQuery<PlayerStats>({
    queryKey: ['player', name],
    queryFn: () => getPlayerStats(decodeURIComponent(name!)),
    enabled: !!name,
  })
}
