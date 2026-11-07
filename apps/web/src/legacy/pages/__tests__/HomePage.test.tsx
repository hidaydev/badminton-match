import { beforeEach, describe, expect, it } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { CommunityContext, type CommunityContextValue } from '../../../community/CommunityContext'
import type { Membership } from '../../../auth/api'
import { mockFetch } from '../../../test/fetchMock'
import { t } from '../../../i18n'
import { LegacySlugProvider } from '../../router'
import HomePage from '../HomePage'

const acme: Membership = { id: 'c1', slug: 'acme', name: 'Acme', role: 'member' }

const community: CommunityContextValue = {
  memberships: [acme],
  current: acme,
  select: () => {},
}

type Row = {
  id: string
  title: string
  date: string
  status: string
  playerCount: number
  totalGames: number
}

function row(overrides: Partial<Row> & Pick<Row, 'id' | 'title' | 'date'>): Row {
  return {
    status: 'draft',
    playerCount: 8,
    totalGames: 5,
    ...overrides,
  }
}

const bootstrap = {
  'GET /api/c/acme/players?mine=1': () => ({ body: { items: [] } }),
}

function sessionsFetch(items: Row[], total = items.length) {
  return mockFetch({
    ...bootstrap,
    'GET /api/c/acme/sessions?limit=100': () => ({ body: { items, total } }),
  })
}

function LocationProbe() {
  return <span data-testid="pathname">{useLocation().pathname}</span>
}

function renderHome() {
  return render(
    <QueryClientProvider
      client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}
    >
      <CommunityContext.Provider value={community}>
        <MemoryRouter initialEntries={['/c/acme']}>
          <LegacySlugProvider slug="acme">
            <Routes>
              <Route path="/c/acme" element={<HomePage />} />
              <Route path="*" element={<LocationProbe />} />
            </Routes>
          </LegacySlugProvider>
        </MemoryRouter>
      </CommunityContext.Provider>
    </QueryClientProvider>,
  )
}

describe('HomePage continue-session card', () => {
  beforeEach(() => {
    window.localStorage.clear()
    // The query key and the request path both read the slug from the URL.
    window.history.replaceState({}, '', '/c/acme')
  })

  it('points at the newest draft with its date and counts', async () => {
    sessionsFetch([
      row({ id: 's1', title: 'Sunday draft', date: '2026-11-08' }),
      row({ id: 's0', title: 'Older draft', date: '2026-11-01' }),
    ])

    renderHome()

    expect(await screen.findByText('Sunday draft')).toBeInTheDocument()
    expect(screen.getByText(t('home.continueSession'))).toBeInTheDocument()
    expect(screen.getByText('08-11-2026')).toBeInTheDocument()
    expect(screen.getByText('8p · 5g')).toBeInTheDocument()

    fireEvent.click(screen.getByText('Sunday draft'))
    expect(screen.getByTestId('pathname')).toHaveTextContent('/c/acme/s/s1')
  })

  it('renders no card when every session is finished', async () => {
    const fetchMock = sessionsFetch([
      row({ id: 's1', title: 'Locked night', date: '2026-11-08', status: 'locked' }),
      row({ id: 's2', title: 'Published cup', date: '2026-11-02', status: 'published' }),
    ])

    renderHome()

    await waitFor(() =>
      expect(
        fetchMock.mock.calls.some(([url]) => String(url) === '/api/c/acme/sessions?limit=100'),
      ).toBe(true),
    )
    expect(screen.queryByText(t('home.continueSession'))).not.toBeInTheDocument()
    expect(screen.queryByText('Locked night')).not.toBeInTheDocument()
  })

  it('takes the first draft in the server order: newer date, then newer update', async () => {
    // The endpoint answers ordered by session_date desc, updated_at desc; the
    // card reads that order instead of re-sorting a row that carries no
    // updated_at. Same-date rows arrive newest update first for the same reason.
    sessionsFetch([
      row({ id: 's-new', title: 'Newest draft', date: '2026-11-08' }),
      row({ id: 's-same-late', title: 'Same day, edited later', date: '2026-11-05' }),
      row({ id: 's-same-early', title: 'Same day, edited earlier', date: '2026-11-05' }),
    ])

    renderHome()

    expect(await screen.findByText('Newest draft')).toBeInTheDocument()
    expect(screen.queryByText('Same day, edited later')).not.toBeInTheDocument()
    expect(screen.queryByText('Same day, edited earlier')).not.toBeInTheDocument()
  })

  it('ignores the session this device visited last', async () => {
    window.localStorage.setItem(
      'last-visited-session',
      JSON.stringify({
        id: 'stale',
        slug: 'acme',
        title: 'Stale visit',
        date: '2026-10-01',
        playerCount: 4,
        totalGames: 2,
        locked: true,
      }),
    )
    sessionsFetch([row({ id: 's1', title: 'Sunday draft', date: '2026-11-08' })])

    renderHome()

    expect(await screen.findByText('Sunday draft')).toBeInTheDocument()
    expect(screen.queryByText('Stale visit')).not.toBeInTheDocument()
    fireEvent.click(screen.getByText('Sunday draft'))
    expect(screen.getByTestId('pathname')).toHaveTextContent('/c/acme/s/s1')
  })
})