import { describe, expect, it } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import App from '../../App'
import type { Membership } from '../../auth/api'
import { t } from '../../i18n'
import { mockFetch } from '../../test/fetchMock'

const sessionUser = { id: 'u1', displayName: 'Ada', platformOwner: false }
const acme: Membership = { id: 'c1', slug: 'acme', name: 'Acme', role: 'member' }

const detail = {
  id: 's1',
  title: 'Wednesday Night',
  date: '2026-11-04',
  startTime: '19:00',
  slotMinutes: 30,
  status: 'locked',
  version: 3,
  participants: [
    { playerId: 'p1', name: 'Ani', absent: false },
    { playerId: 'p2', name: 'Budi', absent: true },
  ],
  games: [
    {
      round: 0,
      court: 0,
      sideA: ['p1'],
      sideB: ['p2'],
      scoreA: 30,
      scoreB: 24,
      status: 'played',
    },
  ],
}

const board = {
  sessionId: 's1',
  title: 'Wednesday Night',
  date: '2026-11-04',
  items: [
    {
      playerId: 'p1',
      name: 'Ani',
      wins: 1,
      losses: 0,
      pointsFor: 30,
      pointsAgainst: 24,
      diff: 6,
    },
  ],
}

function renderAt(path: string) {
  window.history.replaceState({}, '', path)
  return render(<App />)
}

describe('session read', () => {
  it('lists the sessions and opens one with its games and board', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [acme] } }),
      'GET /api/c/acme/sessions': () => ({
        body: {
          items: [
            {
              id: 's1',
              title: 'Wednesday Night',
              date: '2026-11-04',
              status: 'locked',
              version: 3,
            },
          ],
        },
      }),
      'GET /api/c/acme/sessions/s1': () => ({ body: detail }),
      'GET /api/c/acme/sessions/s1/standings': () => ({ body: board }),
    })

    renderAt('/c/acme/sessions')

    expect(await screen.findByRole('heading', { name: t('sessions.title') })).toBeInTheDocument()
    const link = await screen.findByRole('link', { name: /Wednesday Night/ })
    fireEvent.click(link)

    expect(await screen.findByRole('heading', { name: 'Wednesday Night' })).toBeInTheDocument()
    expect(screen.getByText(/19:00/)).toBeInTheDocument()
    expect(screen.getByText('30–24')).toBeInTheDocument()
    expect(screen.getByText(new RegExp(t('session.absent')))).toBeInTheDocument()
    expect(screen.getByRole('columnheader', { name: t('session.column.diff') })).toBeInTheDocument()
  })

  it('reports a session that does not exist instead of an empty page', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [acme] } }),
      'GET /api/c/acme/sessions/s9': () => ({
        status: 404,
        body: { code: 'NOT_FOUND' },
      }),
      'GET /api/c/acme/sessions/s9/standings': () => ({
        status: 404,
        body: { code: 'NOT_FOUND' },
      }),
    })

    renderAt('/c/acme/sessions/s9')

    expect(await screen.findByText(t('session.error.notFound'))).toBeInTheDocument()
  })
})
