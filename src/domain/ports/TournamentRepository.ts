import type { TournamentSnapshot } from '../../utils/tournament'

export interface TournamentRepository {
  getTournament(id: string): Promise<TournamentSnapshot | null>
  publishTournament(id: string, data: TournamentSnapshot): Promise<TournamentSnapshot>
}
