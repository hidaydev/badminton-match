import { describe, expect, it } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import App from '../../App'
import { t } from '../../i18n'
import { jsonBody, mockFetch } from '../../test/fetchMock'

const sessionUser = { id: 'u1', displayName: 'Ada', platformOwner: false }
const admin = { id: 'c1', slug: 'acme', name: 'Acme', role: 'admin' }

const members = {
  items: [
    {
      userId: 'u1',
      displayName: 'Ada',
      role: 'admin',
      joinedAt: '2026-11-01 10:00:00+07',
    },
  ],
}

const requests = {
  items: [
    {
      id: 'r1',
      userId: 'u7',
      displayName: 'Budi',
      createdAt: '2026-11-02 09:00:00+07',
    },
  ],
}

function renderAt(path: string) {
  window.history.replaceState({}, '', path)
  return render(<App />)
}

function base(extra: Record<string, () => { status?: number; body?: unknown }>) {
  return mockFetch({
    'GET /api/auth/me': () => ({ body: sessionUser }),
    'GET /api/communities': () => ({ body: { items: [admin] } }),
    'GET /api/c/acme/members': () => ({ body: members }),
    'GET /api/c/acme/join-requests': () => ({ body: requests }),
    ...extra,
  })
}

describe('community settings', () => {
  it('creates an invite and shows the token once', async () => {
    const fetchMock = base({
      'POST /api/c/acme/invites': () => ({
        status: 201,
        body: { token: 'tok_abc', expiresInDays: 7, role: 'host' },
      }),
    })

    renderAt('/c/acme/settings')

    fireEvent.change(await screen.findByLabelText(t('admin.invites.email')), {
      target: { value: 'host@example.com' },
    })
    fireEvent.change(screen.getByLabelText(t('admin.invites.role')), {
      target: { value: 'host' },
    })
    fireEvent.click(screen.getByRole('button', { name: t('admin.invites.create') }))

    expect(await screen.findByText('tok_abc')).toBeInTheDocument()
    const call = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url) === '/api/c/acme/invites' &&
        (init as RequestInit | undefined)?.method === 'POST',
    )
    expect(jsonBody((call as [string, RequestInit])[1])).toEqual({
      email: 'host@example.com',
      role: 'host',
    })
  })

  it('answers a join request', async () => {
    const fetchMock = base({
      'PATCH /api/c/acme/join-requests/r1': () => ({ body: { status: 'approved' } }),
    })

    renderAt('/c/acme/settings')

    fireEvent.click(await screen.findByRole('button', { name: t('admin.requests.approve') }))
    await waitFor(() => {
      expect(
        fetchMock.mock.calls.some(
          ([url, init]) =>
            String(url) === '/api/c/acme/join-requests/r1' &&
            (init as RequestInit | undefined)?.method === 'PATCH',
        ),
      ).toBe(true)
    })
  })
})
