import { beforeEach, describe, expect, it, vi } from 'vitest'

vi.mock('../../../auth/redirect', () => ({ redirectTo: vi.fn() }))
import { render, screen, waitFor } from '@testing-library/react'
import App from '../../../App'
import { t } from '../../../i18n'
import { mockFetch } from '../../../test/fetchMock'

const sessionUser = { id: 'u1', displayName: 'Ada', platformOwner: false }
const acme = { id: 'c1', slug: 'acme', name: 'Acme', role: 'member' }

const bootstrap = {
  'GET /api/auth/me': () => ({ body: sessionUser }),
  'GET /api/communities': () => ({ body: { items: [acme] } }),
  'GET /api/c/acme/players?limit=1000': () => ({ body: { items: [] } }),
}

describe('legacy ratings routes', () => {
  beforeEach(() => {
    window.localStorage.clear()
    window.sessionStorage.clear()
  })

  // MAJ-06: a bookmarked player rating used to lose its player and land on the
  // list, so a shared link opened the wrong screen.
  it('keeps the player when an old ratings link is followed', async () => {
    mockFetch({
      ...bootstrap,
      'GET /api/c/acme/players/p1/stats': () => ({
        body: {
          player: { id: 'p1', name: 'Ani' },
          games: 0,
          wins: 0,
          losses: 0,
          rating: { points: 1450, tier: 3 },
          history: [],
        },
      }),
      'GET /api/c/acme/players/p1/achievements': () => ({ body: { items: [] } }),
    })

    window.history.replaceState({}, '', '/c/acme/ratings/p1')
    render(<App />)

    // The redirect is a history replacement; the path is what proves the id
    // survived it rather than being dropped on the way to the list.
    await waitFor(() => expect(window.location.pathname).toBe('/c/acme/rankings/p1'))
    expect(screen.queryByRole('heading', { name: t('rankings.title') })).toBeNull()
  })

  it('still sends the list path to the rankings list', async () => {
    mockFetch({
      ...bootstrap,
      'GET /api/c/acme/rankings': () => ({ body: { items: [], total: 0 } }),
    })

    window.history.replaceState({}, '', '/c/acme/ratings')
    render(<App />)

    expect(
      await screen.findByRole('heading', { name: t('rankings.title') }),
    ).toBeInTheDocument()
    expect(window.location.pathname).toBe('/c/acme/rankings')
  })
})
