import { beforeEach, describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import App from '../../App'
import type { Membership } from '../../auth/api'
import { t } from '../../i18n'
import { mockFetch } from '../../test/fetchMock'
import type { Achievement, PlayerStats, RankingRow } from '../../rankings/api'

const sessionUser = { id: 'u1', displayName: 'Ada', platformOwner: false }

const acme: Membership = { id: 'c1', slug: 'acme', name: 'Acme', role: 'member' }

const sessionHandlers = {
  'GET /api/auth/me': () => ({ body: sessionUser }),
  'GET /api/communities': () => ({ body: { items: [acme] } }),
}

const playerRow: RankingRow = {
  rank: 3,
  playerId: 'p1',
  name: 'Ani',
  tier: 'A+',
  points: 245,
  games: 12,
  wins: 9,
  losses: 3,
}

const playerStats: PlayerStats = {
  playerId: 'p1',
  name: 'Ani',
  tier: 'A+',
  gender: 'F',
  points: 245,
  games: 12,
  wins: 9,
  losses: 3,
}

const badge: Achievement = {
  key: 'sessions:10',
  category: 'attendance',
  threshold: 10,
  earnedAt: '2026-02-14 08:30:00+00',
}

const profileHandlers = {
  'GET /api/c/acme/rankings/p1': () => ({ body: playerRow }),
  'GET /api/c/acme/players/p1/stats': () => ({ body: playerStats }),
  'GET /api/c/acme/players/p1/achievements': () => ({ body: { items: [badge] } }),
}

function renderAt(path: string) {
  window.history.replaceState({}, '', path)
  return render(<App />)
}

describe('RatingPlayerPage', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it('renders the player, stats and badges from the API payload', async () => {
    mockFetch({ ...sessionHandlers, ...profileHandlers })

    renderAt('/c/acme/rankings/p1')

    expect(await screen.findByRole('heading', { name: 'Ani' })).toBeInTheDocument()
    expect(screen.getByText('A+')).toBeInTheDocument()
    expect(screen.getByText(t('player.rank', { rank: 3 }))).toBeInTheDocument()
    expect(screen.getAllByText('245')).toHaveLength(1)
    expect(screen.getByText('12')).toBeInTheDocument()
    expect(screen.getByText('9')).toBeInTheDocument()
    expect(screen.getByText('3')).toBeInTheDocument()
    expect(screen.getByText(t('player.gender.female'))).toBeInTheDocument()
  })

  it('shows every badge with its earned date', async () => {
    mockFetch({ ...sessionHandlers, ...profileHandlers })

    renderAt('/c/acme/rankings/p1')

    expect(await screen.findByText('sessions:10')).toBeInTheDocument()
    expect(screen.getByText('attendance')).toBeInTheDocument()
    expect(
      screen.getByText(t('player.badge.threshold', { threshold: 10 })),
    ).toBeInTheDocument()
    expect(
      screen.getByText(t('player.badge.earned', { date: '2026-02-14' })),
    ).toBeInTheDocument()
  })

  it('renders an unrated player as Unrated instead of null', async () => {
    mockFetch({
      ...sessionHandlers,
      ...profileHandlers,
      'GET /api/c/acme/rankings/p1': () => ({ body: { ...playerRow, tier: null } }),
      'GET /api/c/acme/players/p1/stats': () => ({ body: { ...playerStats, tier: null } }),
      'GET /api/c/acme/players/p1/achievements': () => ({ body: { items: [] } }),
    })

    renderAt('/c/acme/rankings/p1')

    expect(await screen.findByText(t('rankings.unrated'))).toBeInTheDocument()
    expect(screen.queryByText('null')).not.toBeInTheDocument()
    expect(screen.getByText(t('player.badges.empty'))).toBeInTheDocument()
  })

  it('renders the not found state for an unknown player', async () => {
    mockFetch({
      ...sessionHandlers,
      'GET /api/c/acme/rankings/ghost': () => ({ status: 404, body: { code: 'NOT_FOUND' } }),
      'GET /api/c/acme/players/ghost/stats': () => ({
        status: 404,
        body: { code: 'NOT_FOUND' },
      }),
      'GET /api/c/acme/players/ghost/achievements': () => ({
        status: 404,
        body: { code: 'NOT_FOUND' },
      }),
    })

    renderAt('/c/acme/rankings/ghost')

    expect(await screen.findByText(t('player.error.notFound'))).toBeInTheDocument()
  })
})
