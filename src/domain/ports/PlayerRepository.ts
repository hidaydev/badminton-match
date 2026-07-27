import type { PlayerSummary, PlayerStats } from '../../queries/types'

export interface PlayerRepository {
  listPlayers(): Promise<PlayerSummary[]>
  getPlayerStats(name: string): Promise<PlayerStats>
  registerPlayer(name: string, canonicalName?: string): Promise<{ playerId: string }>
}
