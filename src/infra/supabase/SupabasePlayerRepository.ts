import type { PlayerRepository } from '../../domain/ports/PlayerRepository'
import type { PlayerSummary, PlayerStats } from '../../queries/types'
import { listPlayers, getPlayerStats, registerPlayer } from '../../queries/endpoints'

export class SupabasePlayerRepository implements PlayerRepository {
  async listPlayers(): Promise<PlayerSummary[]> {
    return listPlayers()
  }

  async getPlayerStats(name: string): Promise<PlayerStats> {
    return getPlayerStats(name)
  }

  async registerPlayer(name: string, canonicalName?: string): Promise<{ playerId: string }> {
    return registerPlayer(name, canonicalName)
  }
}
