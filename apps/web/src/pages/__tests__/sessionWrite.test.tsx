import { describe, expect, it } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import App from '../../App'
import type { Membership } from '../../auth/api'
import { t } from '../../i18n'
import { jsonBody, mockFetch } from '../../test/fetchMock'

const sessionUser = { id: 'u1', displayName: 'Ada', platformOwner: false }
const host: Membership = { id: 'c1', slug: 'acme', name: 'Acme', role: 'host' }

const detail = {
  id: 's1',
  title: 'Wednesday Night',
  date: '2026-11-04',
  startTime: '19:00',
  slotMinutes: 30,
  status: 'draft',
  version: 3,
  participants: [
    { playerId: 'p1', name: 'Ani', absent: false },
    { playerId: 'p2', name: 'Budi', absent: false },
  ],
  games: [
    {
      round: 0,
      court: 0,
      sideA: ['p1'],
      sideB: ['p2'],
      scoreA: null,
      scoreB: null,
      status: 'scheduled',
    },
  ],
}

const board = { sessionId: 's1', title: 'Wednesday Night', date: '2026-11-04', items: [] }

function renderAt(path: string) {
  window.history.replaceState({}, '', path)
  return render(<App />)
}

describe('session write', () => {
  it('saves a score with the version it read', async () => {
    const fetchMock = mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [host] } }),
      'GET /api/c/acme/sessions/s1': () => ({ body: detail }),
      'GET /api/c/acme/sessions/s1/standings': () => ({ body: board }),
      'PATCH /api/c/acme/sessions/s1/games/0-0': () => ({
        body: { version: 4 },
      }),
    })

    renderAt('/c/acme/sessions/s1')

    const sideA = await screen.findByLabelText(t('session.column.sideA'))
    fireEvent.change(sideA, { target: { value: '30' } })
    fireEvent.click(screen.getAllByRole('button', { name: t('session.save') })[0])

    await waitFor(() => {
      const call = fetchMock.mock.calls.find(
        ([url]) => String(url) === '/api/c/acme/sessions/s1/games/0-0',
      )
      expect(call).toBeDefined()
      const [, init] = call as [string, RequestInit]
      expect(init.method).toBe('PATCH')
      expect(new Headers(init.headers).get('If-Match')).toBe('"3"')
      expect(jsonBody(init)).toEqual({ scoreA: 30, scoreB: null })
    })
  })

  it('creates a share link when the session has none', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [host] } }),
      'GET /api/c/acme/sessions/s1': () => ({ body: detail }),
      'GET /api/c/acme/sessions/s1/standings': () => ({ body: board }),
      'GET /api/c/acme/sessions/s1/share': () => ({
        status: 404,
        body: { code: 'NOT_FOUND' },
      }),
      'POST /api/c/acme/sessions/s1/share': () => ({
        body: { code: 'abc123', sessionId: 's1' },
      }),
    })

    renderAt('/c/acme/sessions/s1')

    fireEvent.click(await screen.findByRole('button', { name: t('session.share.show') }))
    fireEvent.click(await screen.findByRole('button', { name: t('session.share.create') }))

    expect(await screen.findByText('abc123')).toBeInTheDocument()
  })

  it('keeps the controls away from a member', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({
        body: { items: [{ ...host, role: 'member' }] },
      }),
      'GET /api/c/acme/sessions/s1': () => ({ body: detail }),
      'GET /api/c/acme/sessions/s1/standings': () => ({ body: board }),
    })

    renderAt('/c/acme/sessions/s1')

    await screen.findByRole('heading', { name: 'Wednesday Night' })
    expect(screen.queryByRole('button', { name: t('session.lock') })).not.toBeInTheDocument()
  })
})
