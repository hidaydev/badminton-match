import { describe, expect, it } from 'vitest'
import { fireEvent, render, screen, within } from '@testing-library/react'
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
  it('renders the games a stranger came to see, without any edit control', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ status: 401, body: {} }),
      'GET /api/s/abc123': () => ({ body: shared }),
    })

    renderAt('/s/abc123')

    expect(await screen.findByRole('heading', { name: 'Tuesday Night' })).toBeInTheDocument()
    expect(screen.getByText('Ani & Budi')).toBeInTheDocument()
    expect(screen.getByText('30–24')).toBeInTheDocument()
    expect(screen.getByText('Acme')).toBeInTheDocument()
    // A phone-width day, not the long form that wraps next to the community.
    expect(screen.getByText('Tue, 3 Nov 2026')).toBeInTheDocument()
    expect(screen.getByRole('tab', { name: t('session.games') })).toBeInTheDocument()
    expect(screen.getByRole('tab', { name: t('session.standings') })).toBeInTheDocument()
    expect(screen.queryByRole('textbox')).toBeNull()
  })

  it('counts only played games in the standings tab', async () => {
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

    await screen.findByRole('heading', { name: 'Tuesday Night' })
    fireEvent.click(screen.getByRole('tab', { name: t('session.standings') }))

    const rows = screen.getAllByRole('listitem').map((row) => row.textContent ?? '')
    // One win and one loss from the two played games; the cancelled one is not a result.
    expect(rows.some((row) => row.includes('Ani') && row.includes('1-1'))).toBe(true)
    expect(rows.some((row) => row.includes('Candra') && row.includes('1-1'))).toBe(true)
    // Wins tie, so point difference decides: Candra/Dewi scored 45-48, Ani/Budi 48-45.
    expect(rows[0]).toContain('Ani')
  })

  it('renders the standings the server sent instead of recomputing them', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ status: 401, body: {} }),
      'GET /api/s/abc123': () => ({
        body: {
          ...shared,
          standings: {
            items: [
              {
                name: 'Dewi',
                wins: 0,
                losses: 1,
                pointsFor: 24,
                pointsAgainst: 30,
                diff: -6,
              },
              {
                name: 'Ani',
                wins: 1,
                losses: 0,
                pointsFor: 30,
                pointsAgainst: 24,
                diff: 6,
              },
            ],
          },
        },
      }),
    })

    renderAt('/s/abc123')

    await screen.findByRole('heading', { name: 'Tuesday Night' })
    fireEvent.click(screen.getByRole('tab', { name: t('session.standings') }))

    const list = screen.getByRole('list')
    const rows = within(list).getAllByRole('listitem')
    // The server order is final: the export and this screen share one tally.
    expect(rows.map((row) => row.textContent)).toEqual([
      expect.stringContaining('Dewi'),
      expect.stringContaining('Ani'),
    ])
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