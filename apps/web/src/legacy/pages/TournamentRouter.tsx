import { useParams } from '../router'
import { useGetTournament } from '../queries'
import TournamentPage from './TournamentPage'
import TeamTournamentPage from './TeamTournamentPage'

/** Route detail tournament — branch by format (classic | team). */
export default function TournamentRouter() {
  const { id = '' } = useParams()
  const { data } = useGetTournament(id)

  if (data && data.format === 'team') {
    return <TeamTournamentPage />
  }
  return <TournamentPage />
}
