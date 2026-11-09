import { beforeEach, describe, expect, it } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { CommunityContext, type CommunityContextValue } from '@/community/CommunityContext'
import type { Membership } from '@/auth/api'
import { mockFetch } from '@/test/fetchMock'
import { t } from '@/i18n'
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

/** The card's own read: one draft, so the server picks it, not the first page. */
const draftPath = '/api/c/acme/sessions?limit=1&status=draft'

function sessionsFetch(items: Row[], total = items.length) {
  return mockFetch({
    ...bootstrap,
    [`GET ${draftPath}`]: () => ({
      body: { items, total, nextCursor: '' },
    }),
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

  it('asks the server for one draft and points at it', async () => {
    const fetchMock = sessionsFetch([
      row({ id: 's1', title: 'Sunday draft', date: '2026-11-08' }),
    ])

    renderHome()

    expect(await screen.findByText('Sunday draft')).toBeInTheDocument()
    expect(screen.getByText(t('home.continueSession'))).toBeInTheDocument()
    expect(screen.getByText('08-11-2026')).toBeInTheDocument()
    expect(screen.getByText('8p · 5g')).toBeInTheDocument()
    expect(
      fetchMock.mock.calls.some(([url]) => String(url) === draftPath),
    ).toBe(true)

    fireEvent.click(screen.getByText('Sunday draft'))
    expect(screen.getByTestId('pathname')).toHaveTextContent('/c/acme/s/s1')
  })

  it('renders no card when the server reports no draft', async () => {
    const fetchMock = sessionsFetch([], 3)

    renderHome()

    await waitFor(() =>
      expect(fetchMock.mock.calls.some(([url]) => String(url) === draftPath)).toBe(true),
    )
    await waitFor(() =>
      expect(screen.queryByText(t('home.continue.loading'))).not.toBeInTheDocument(),
    )
    expect(screen.queryByText(t('home.continueSession'))).not.toBeInTheDocument()
  })

  it('shows a retry row when the draft read fails instead of hiding the card', async () => {
    let fail = true
    const fetchMock = mockFetch({
      ...bootstrap,
      [`GET ${draftPath}`]: () =>
        fail
          ? { status: 500, body: { code: 'INTERNAL', detail: 'boom' } }
          : {
              body: {
                items: [row({ id: 's1', title: 'Sunday draft', date: '2026-11-08' })],
                total: 1,
                nextCursor: '',
              },
            },
    })

    renderHome()

    // The transport retries a read three times with backoff before the card
    // can report the failure.
    const alert = await screen.findByRole('alert', {}, { timeout: 20000 })
    expect(alert).toHaveTextContent(t('home.continue.error'))
    expect(screen.queryByText(t('home.continueSession'))).not.toBeInTheDocument()

    fail = false
    fireEvent.click(screen.getByRole('button', { name: t('home.continue.retry') }))

    expect(await screen.findByText('Sunday draft')).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(
      fetchMock.mock.calls.filter(([url]) => String(url) === draftPath),
    ).toHaveLength(5)
  }, 30000)

  it('offers the draft the server found beyond its first page', async () => {
    // The community has 150 sessions and the newest draft is the 120th row;
    // the server filter returns it as the only item of a one-row page.
    sessionsFetch([
      row({ id: 's-120', title: 'The 120th draft', date: '2026-05-04' }),
    ], 150)

    renderHome()

    expect(await screen.findByText('The 120th draft')).toBeInTheDocument()
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
