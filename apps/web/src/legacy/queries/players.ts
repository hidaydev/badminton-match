import { useQuery } from '@tanstack/react-query'
import { listPlayers, getPlayerStats } from './endpoints'
import type { PlayerSummary, PlayerStats } from './types'

export function useListPlayers() {
  return useQuery<PlayerSummary[]>({
    queryKey: ['players'],
    queryFn: ({ signal }) => listPlayers(signal),
  })
}

export function useGetPlayerStats(name: string | undefined) {
  return useQuery<PlayerStats>({
    queryKey: ['player', name],
    queryFn: ({ signal }) => getPlayerStats(decodeURIComponent(name!), signal),
    enabled: !!name,
  })
}
