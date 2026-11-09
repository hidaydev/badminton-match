import { beforeEach, describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import type { ReactElement } from 'react'
import type { TournamentSnapshot } from '../../utils/tournament'
import { TEAM_NAMES, type TeamTournamentSnapshot } from '../../utils/teamTournament'
import { mockFetch } from '@/test/fetchMock'
import { t } from '@/i18n'
import { LegacySlugProvider } from '../../router'
import TournamentPage from '../TournamentPage'
import TournamentRouter from '../TournamentRouter'

const DETAIL = 'GET /api/c/acme/tournaments/t1'

const classic: TournamentSnapshot = {
  format: 'classic',
  version: 3,
  name: 'Sunday Cup',
  date: '2026-11-08',
  pairs: [
    { id: 'pair-1', name: 'Arya/Bima' },
    { id: 'pair-2', name: 'Cici/Dewi' },
  ],
  groups: { A: [], B: [], C: [], D: [] },
  matches: [],
}

const team: TeamTournamentSnapshot = {
  format: 'team',
  version: 1,
  name: 'Team Cup',
  date: '2026-11-08',
  teams: TEAM_NAMES.map((name, i) => ({ id: `team-${i}`, name, players: [] })),
  matches: [],
}

function renderInTournamentRoute(element: ReactElement) {
  return render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <MemoryRouter initialEntries={['/c/acme/tournaments/t1']}>
        <LegacySlugProvider slug="acme">
          <Routes>
            <Route path="/c/acme/tournaments/:id" element={element} />
          </Routes>
        </LegacySlugProvider>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('TournamentPage', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.history.replaceState({}, '', '/c/acme')
  })

  it('renders the classic tabs and header for a classic snapshot', async () => {
    mockFetch({ [DETAIL]: () => ({ body: classic }) })

    renderInTournamentRoute(<TournamentPage />)

    expect(await screen.findByRole('heading', { name: 'Sunday Cup' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Groups' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Bracket' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Standings' })).toBeInTheDocument()
  })

  it('renders no classic content for a team snapshot', async () => {
    mockFetch({ [DETAIL]: () => ({ body: team }) })

    renderInTournamentRoute(<TournamentPage />)

    // The group editor placeholder only appears once the snapshot has landed.
    expect(
      await screen.findByText('Groups have not been drawn yet. A host or admin assigns them.'),
    ).toBeInTheDocument()
    // A team snapshot is narrowed away: it must not leak its name into the
    // classic header.
    expect(screen.queryByText('Team Cup')).not.toBeInTheDocument()
  })

  it('shows the not-found message for a 404 instead of an empty bracket', async () => {
    mockFetch({
      [DETAIL]: () => ({
        status: 404,
        body: { code: 'NOT_FOUND', detail: 'no such tournament' },
      }),
    })

    renderInTournamentRoute(<TournamentPage />)

    expect(await screen.findByText(t('tournaments.error.notFound'))).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Bracket' })).not.toBeInTheDocument()
  })
})

describe('TournamentRouter', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.history.replaceState({}, '', '/c/acme')
  })

  it('renders the team screen when the record format is team', async () => {
    mockFetch({ [DETAIL]: () => ({ body: team }) })

    renderInTournamentRoute(<TournamentRouter />)

    expect(await screen.findByRole('heading', { name: 'Team Cup' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Schedule' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Final' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Bracket' })).not.toBeInTheDocument()
  })

  it('renders the classic screen for any other format', async () => {
    mockFetch({ [DETAIL]: () => ({ body: classic }) })

    renderInTournamentRoute(<TournamentRouter />)

    expect(await screen.findByRole('heading', { name: 'Sunday Cup' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Bracket' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Schedule' })).not.toBeInTheDocument()
  })
})