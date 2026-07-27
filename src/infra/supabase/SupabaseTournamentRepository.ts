import type { TournamentRepository } from '../../domain/ports/TournamentRepository'
import type { TournamentSnapshot } from '../../utils/tournament'
import { getTournament, publishTournament } from '../../queries/endpoints'

export class SupabaseTournamentRepository implements TournamentRepository {
  async getTournament(id: string): Promise<TournamentSnapshot | null> {
    return getTournament(id)
  }

  async publishTournament(id: string, data: TournamentSnapshot): Promise<TournamentSnapshot> {
    return publishTournament(id, data)
  }
}
