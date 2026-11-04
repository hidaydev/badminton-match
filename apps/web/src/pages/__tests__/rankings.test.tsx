import { beforeEach, describe, expect, it } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import App from '../../App'
import type { Membership } from '../../auth/api'
import { t } from '../../i18n'
import { mockFetch } from '../../test/fetchMock'
import type { RankingRow } from '../../rankings/api'

const sessionUser = { id: 'u1', displayName: 'Ada', platformOwner: false }

const acme: Membership = { id: 'c1', slug: 'acme', name: 'Acme', role: 'member' }

const sessionHandlers = {
  'GET /api/auth/me': () => ({ body: sessionUser }),
  'GET /api/communities': () => ({ body: { items: [acme] } }),
}

function row(index: number): RankingRow {
  return {
    rank: index + 1,
    playerId: `p${index + 1}`,
    name: `Player ${index + 1}`,
    tier: 'B',
    points: 1000 - index,
    games: 10,
    wins: 6,
    losses: 4,
  }
}

function renderAt(path: string) {
  window.history.replaceState({}, '', path)
  return render(<App />)
}

describe('RankingsPage', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it('renders one row per item the API returns, even above 200', async () => {
    const items = Array.from({ length: 250 }, (_, index) => row(index))
    mockFetch({
      ...sessionHandlers,
      'GET /api/c/acme/rankings': () => ({ body: { asOf: '2026-11-04', items } }),
    })

    const { container } = renderAt('/c/acme/rankings')

    expect(await screen.findByRole('heading', { name: t('rankings.title') })).toBeInTheDocument()
    await waitFor(() => expect(container.querySelectorAll('tbody tr')).toHaveLength(250))
    expect(screen.getByText(t('rankings.asOf', { date: '2026-11-04' }))).toBeInTheDocument()
  })

  it('sends the tier filter as a query parameter and keeps the slug', async () => {
    const fetchMock = mockFetch({
      ...sessionHandlers,
      'GET /api/c/acme/rankings': () => ({
        body: { asOf: '2026-11-04', items: [row(0)] },
      }),
      'GET /api/c/acme/rankings?tier=B': () => ({
        body: {
          asOf: '2026-11-04',
          items: [{ ...row(1), playerId: 'p9', name: 'Budi', rank: 1 }],
        },
      }),
    })

    renderAt('/c/acme/rankings')

    expect(await screen.findByText('Player 1')).toBeInTheDocument()

    fireEvent.change(screen.getByLabelText(t('rankings.filter.tier')), {
      target: { value: 'B' },
    })

    expect(await screen.findByText('Budi')).toBeInTheDocument()
    expect(window.location.pathname).toBe('/c/acme/rankings')
    expect(window.location.search).toBe('?tier=B')

    const urls = fetchMock.mock.calls.map(([url]) => String(url))
    expect(urls).toContain('/api/c/acme/rankings')
    expect(urls.filter((url) => url === '/api/c/acme/rankings?tier=B')).toHaveLength(1)
  })

  it('renders the empty state when the board has no rows', async () => {
    mockFetch({
      ...sessionHandlers,
      'GET /api/c/acme/rankings': () => ({ body: { asOf: '2026-11-04', items: [] } }),
    })

    renderAt('/c/acme/rankings')

    expect(await screen.findByText(t('rankings.empty'))).toBeInTheDocument()
  })

  it('renders a load error', async () => {
    mockFetch({
      ...sessionHandlers,
      'GET /api/c/acme/rankings': () => ({ status: 500, body: { code: 'UNKNOWN' } }),
    })

    renderAt('/c/acme/rankings')

    expect(await screen.findByText(t('rankings.error.load'))).toBeInTheDocument()
  })

  it('renders the non-member state for a foreign community', async () => {
    mockFetch({
      ...sessionHandlers,
      'GET /api/c/ghost/rankings': () => ({ status: 404, body: { code: 'NOT_FOUND' } }),
    })

    renderAt('/c/ghost/rankings')

    expect(await screen.findByText(t('rankings.error.notFound'))).toBeInTheDocument()
  })
})
