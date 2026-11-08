import { beforeEach, describe, expect, it } from 'vitest'
import { fireEvent, render, screen, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { mockFetch } from '../../../test/fetchMock'
import { t } from '../../../i18n'
import { LegacySlugProvider } from '../../router'
import RankingsPage from '../RankingsPage'

type ApiRankRow = {
  rank: number
  playerId: string
  name: string
  tier: string | null
  points: number
  games: number
  rankDelta?: number | null
}

const BOARD = 'GET /api/c/acme/rankings?limit=200&min_sessions=0'

const rows: ApiRankRow[] = [
  { rank: 1, playerId: 'p1', name: 'Ayah', tier: 'A+', points: 1000, games: 12 },
  { rank: 2, playerId: 'p2', name: 'Bima', tier: 'A+', points: 1000, games: 9 },
  { rank: 3, playerId: 'p3', name: 'Cici', tier: 'C', points: 500, games: 6 },
]

function SearchProbe() {
  return <span data-testid="search">{useLocation().search}</span>
}

function renderRankings() {
  return render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <MemoryRouter initialEntries={['/c/acme/rankings']}>
        <LegacySlugProvider slug="acme">
          <Routes>
            <Route
              path="/c/acme/rankings"
              element={
                <>
                  <RankingsPage />
                  <SearchProbe />
                </>
              }
            />
          </Routes>
        </LegacySlugProvider>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('RankingsPage', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.history.replaceState({}, '', '/c/acme')
  })

  it('narrows the rows to the chosen tier while the chips keep counting the whole board', async () => {
    mockFetch({
      [BOARD]: () => ({
        body: {
          windowWeeks: 12,
          bestN: 5,
          minSessions: 0,
          asOf: '2026-11-08',
          items: rows,
        },
      }),
    })

    renderRankings()

    expect(await screen.findByText('Ayah')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^All\s*\(3\)$/ })).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: /^A\+\s*\(2\)$/ }))

    expect(screen.queryByText('Cici')).not.toBeInTheDocument()
    expect(screen.getByText('Bima')).toBeInTheDocument()
    // The chip counts stay board-wide; the subtitle is the line that follows
    // the filter and names the tier.
    expect(screen.getByRole('button', { name: /^A\+\s*\(2\)$/ })).toBeInTheDocument()
    expect(screen.getByText(t('rankings.tierSubtitle', { tier: 'A+' }))).toBeInTheDocument()
    expect(screen.getByTestId('search')).toHaveTextContent('tier=A%2B')
  })

  it('gives tied rows the same intra-tier rank while their global rank stays apart', async () => {
    mockFetch({
      [BOARD]: () => ({
        body: { windowWeeks: 12, bestN: 5, minSessions: 0, asOf: '2026-11-08', items: rows },
      }),
    })

    renderRankings()

    expect(await screen.findByText('Ayah')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /^A\+\s*\(2\)$/ }))

    const filtered = screen.getAllByRole('listitem')
    expect(filtered).toHaveLength(2)
    // First row: intra-tier #1 and global #1.
    expect(within(filtered[0]).getAllByText('#1')).toHaveLength(2)
    // Second row ties on points, so its intra-tier rank is #1 as well while the
    // global rank beside it is #2.
    expect(within(filtered[1]).getByText('#1')).toBeInTheDocument()
    expect(within(filtered[1]).getByText('#2')).toBeInTheDocument()
  })
})