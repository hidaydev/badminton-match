import { describe, expect, it } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import App from '../../App'
import { t } from '../../i18n'
import { mockFetch } from '../../test/fetchMock'

const shared = {
  session: {
    id: 's1',
    title: 'Tuesday Night',
    date: '2026-11-03',
    status: 'locked',
  },
  community: { slug: 'acme', name: 'Acme' },
  games: [
    {
      id: 'g1',
      round: 0,
      court: 0,
      sideA: ['Ani', 'Budi'],
      sideB: ['Candra', 'Dewi'],
      scoreA: 30,
      scoreB: 24,
      status: 'played',
    },
  ],
}

function renderAt(path: string) {
  window.history.replaceState({}, '', path)
  return render(<App />)
}

describe('shared session', () => {
  it('renders the games a stranger came to see, without any control', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ status: 401, body: {} }),
      'GET /api/s/abc123': () => ({ body: shared }),
    })

    renderAt('/s/abc123')

    expect(await screen.findByRole('heading', { name: 'Tuesday Night' })).toBeInTheDocument()
    expect(screen.getByText('Ani & Budi')).toBeInTheDocument()
    expect(screen.getByText('30–24')).toBeInTheDocument()
    expect(screen.getByText('Acme')).toBeInTheDocument()
    expect(screen.queryByRole('button')).toBeNull()
    expect(screen.queryByRole('textbox')).toBeNull()
  })

  it('counts only played games in the standings', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ status: 401, body: {} }),
      'GET /api/s/abc123': () => ({
        body: {
          ...shared,
          games: [
            ...shared.games,
            {
              id: 'g2',
              round: 1,
              court: 0,
              sideA: ['Ani', 'Budi'],
              sideB: ['Candra', 'Dewi'],
              scoreA: 18,
              scoreB: 21,
              status: 'played',
            },
            {
              id: 'g3',
              round: 2,
              court: 0,
              sideA: ['Ani', 'Candra'],
              sideB: ['Budi', 'Dewi'],
              scoreA: 21,
              scoreB: 19,
              status: 'cancelled',
            },
          ],
        },
      }),
    })

    renderAt('/s/abc123')

    expect(await screen.findByRole('heading', { name: t('session.standings') })).toBeInTheDocument()
    const table = screen.getByRole('table', { name: t('session.standings') })
    const rows = within(table).getAllByRole('row').map((row) => row.textContent ?? '')
    // One win each over two games: Ani and Budi are 1 win, 1 loss from 2 games.
    expect(rows.some((row) => row.includes('Ani') && row.includes('2') && row.includes('1'))).toBe(true)
    // The cancelled game is not a result, so it adds no standing.
    expect(rows.some((row) => row.includes('Ani') && row.includes('Candra'))).toBe(false)
  })

  it('says the link is gone instead of showing an empty session', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ status: 401, body: {} }),
      'GET /api/s/rotated': () => ({ status: 404, body: { code: 'NOT_FOUND' } }),
    })

    renderAt('/s/rotated')

    expect(await screen.findByText(t('shared.error.missing'))).toBeInTheDocument()
  })
})
