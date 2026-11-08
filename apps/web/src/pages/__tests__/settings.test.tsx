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

const pendingClaims = {
  items: [
    {
      claimId: 'cl1',
      playerId: 'p1',
      playerName: 'Sari',
      userId: 'u9',
      displayName: 'Citra',
      createdAt: '2026-11-03 08:00:00+07',
    },
  ],
}

function renderAt(path: string) {
  window.history.replaceState({}, '', path)
  return render(<App />)
}

const effective = {
  'community.default_timezone': { value: 'Asia/Jakarta', source: 'platform' },
  'community.invite_ttl_days': { value: 7, source: 'platform' },
  'community.directory_enabled': { value: false, source: 'platform', widenable: true },
  // No `widenable`: the client must read that as a ceiling, not as opt-in.
  'community.join_requests_enabled': { value: false, source: 'platform' },
}

function base(extra: Record<string, () => { status?: number; body?: unknown }>) {
  return mockFetch({
    'GET /api/auth/me': () => ({ body: sessionUser }),
    'GET /api/communities': () => ({ body: { items: [admin] } }),
    'GET /api/c/acme/members': () => ({ body: members }),
    'GET /api/c/acme/join-requests': () => ({ body: requests }),
    'GET /api/c/acme/claims': () => ({ body: { items: [] } }),
    'GET /api/c/acme/config': () => ({ body: { effective } }),
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

  it('opens the effective settings only when its summary is used', async () => {
    base({})

    renderAt('/c/acme/settings')

    const timezone = await screen.findByLabelText(t('community.setting.timezone'))
    const panel = timezone.closest('details')
    if (!(panel instanceof HTMLDetailsElement)) {
      throw new Error('the settings block is not a disclosure element')
    }
    expect(panel.open).toBe(false)

    fireEvent.click(screen.getByText(t('community.settings'), { selector: 'summary' }))
    expect(panel.open).toBe(true)
  })

  it('narrows an invite lifetime and sends only the changed key', async () => {
    let configReads = 0
    const fetchMock = base({
      'GET /api/c/acme/config': () => {
        configReads += 1
        return {
          body: {
            effective:
              configReads === 1
                ? effective
                : {
                    ...effective,
                    'community.invite_ttl_days': { value: 3, source: 'community' },
                  },
          },
        }
      },
      'PATCH /api/c/acme/settings': () => ({
        body: { values: { 'community.invite_ttl_days': 3 } },
      }),
    })

    renderAt('/c/acme/settings')

    const input = await screen.findByLabelText(t('community.setting.inviteTtl'))
    expect(input).toHaveValue(7)
    fireEvent.change(input, { target: { value: '3' } })
    fireEvent.click(screen.getByRole('button', { name: t('community.settings.save') }))

    await waitFor(() => {
      expect(screen.getByText(t('community.settings.saved'))).toBeInTheDocument()
    })
    const call = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url) === '/api/c/acme/settings' &&
        (init as RequestInit | undefined)?.method === 'PATCH',
    )
    expect(jsonBody((call as [string, RequestInit])[1])).toEqual({
      'community.invite_ttl_days': 3,
    })
    expect(input).toHaveValue(3)
  })

  it('locks a switch the platform pinned off and never sends it', async () => {
    const fetchMock = base({
      'PATCH /api/c/acme/settings': () => ({
        body: { values: { 'community.invite_ttl_days': 3 } },
      }),
    })

    renderAt('/c/acme/settings')

    const pinned = await screen.findByLabelText(t('community.setting.joinRequests'))
    expect(pinned).not.toBeChecked()
    expect(pinned).toBeDisabled()
    expect(pinned).toHaveAccessibleDescription(t('community.setting.lockedByPlatform'))

    // The server marks the directory widenable, so its switch stays.
    expect(screen.getByLabelText(t('community.setting.directory'))).toBeEnabled()

    fireEvent.click(pinned)
    expect(pinned).not.toBeChecked()

    fireEvent.change(screen.getByLabelText(t('community.setting.inviteTtl')), {
      target: { value: '3' },
    })
    fireEvent.click(screen.getByRole('button', { name: t('community.settings.save') }))

    await waitFor(() => {
      expect(screen.getByText(t('community.settings.saved'))).toBeInTheDocument()
    })
    const call = fetchMock.mock.calls.find(
      ([url, init]) =>
        String(url) === '/api/c/acme/settings' &&
        (init as RequestInit | undefined)?.method === 'PATCH',
    )
    expect(jsonBody((call as [string, RequestInit])[1])).toEqual({
      'community.invite_ttl_days': 3,
    })
  })

  it('lets an admin turn on a flag the platform allows widening', async () => {
    const fetchMock = base({
      'PATCH /api/c/acme/settings': () => ({
        body: { values: { 'community.directory_enabled': true } },
      }),
    })

    renderAt('/c/acme/settings')

    const directory = await screen.findByLabelText(t('community.setting.directory'))
    expect(directory).toBeEnabled()
    fireEvent.click(directory)
    fireEvent.click(screen.getByRole('button', { name: t('community.settings.save') }))

    await waitFor(() => {
      const call = fetchMock.mock.calls.find(
        ([url, init]) =>
          String(url) === '/api/c/acme/settings' &&
          (init as RequestInit | undefined)?.method === 'PATCH',
      )
      expect(jsonBody((call as [string, RequestInit])[1])).toEqual({
        'community.directory_enabled': true,
      })
    })
  })

  it('follows the server rather than the key name when a flag is widenable', async () => {
    const fetchMock = base({
      'GET /api/c/acme/config': () => ({
        body: {
          effective: {
            ...effective,
            'community.join_requests_enabled': {
              value: false,
              source: 'platform',
              widenable: true,
            },
          },
        },
      }),
      'PATCH /api/c/acme/settings': () => ({ body: { values: {} } }),
    })

    renderAt('/c/acme/settings')

    const join = await screen.findByLabelText(t('community.setting.joinRequests'))
    expect(join).toBeEnabled()
    fireEvent.click(join)
    fireEvent.click(screen.getByRole('button', { name: t('community.settings.save') }))

    await waitFor(() => {
      const call = fetchMock.mock.calls.find(
        ([url, init]) =>
          String(url) === '/api/c/acme/settings' &&
          (init as RequestInit | undefined)?.method === 'PATCH',
      )
      expect(jsonBody((call as [string, RequestInit])[1])).toEqual({
        'community.join_requests_enabled': true,
      })
    })
  })

  it('shows the reason the server refused a save', async () => {
    const detail =
      'override may not enable a platform-disabled flag: community.join_requests_enabled'
    base({
      'PATCH /api/c/acme/settings': () => ({
        status: 400,
        body: { status: 400, code: 'OVERRIDE_TOO_HIGH', detail },
      }),
    })

    renderAt('/c/acme/settings')

    fireEvent.change(await screen.findByLabelText(t('community.setting.inviteTtl')), {
      target: { value: '3' },
    })
    fireEvent.click(screen.getByRole('button', { name: t('community.settings.save') }))

    expect(await screen.findByText(detail)).toBeInTheDocument()
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

  it('approves a join request with the role the admin picked', async () => {
    const fetchMock = base({
      'PATCH /api/c/acme/join-requests/r1': () => ({ body: { status: 'approved' } }),
    })

    renderAt('/c/acme/settings')

    fireEvent.change(
      await screen.findByLabelText(t('admin.requests.roleOf', { name: 'Budi' })),
      { target: { value: 'host' } },
    )
    fireEvent.click(screen.getByRole('button', { name: t('admin.requests.approve') }))

    await waitFor(() => {
      const call = fetchMock.mock.calls.find(
        ([url, init]) =>
          String(url) === '/api/c/acme/join-requests/r1' &&
          (init as RequestInit | undefined)?.method === 'PATCH',
      )
      expect(jsonBody((call as [string, RequestInit])[1])).toEqual({
        decision: 'approve',
        role: 'host',
      })
    })
    expect(
      await screen.findByText(
        t('admin.requests.granted', { name: 'Budi', role: t('role.host') }),
      ),
    ).toBeInTheDocument()
  })

  it('lists a pending claim and approves it from the queue', async () => {
    let claimReads = 0
    const fetchMock = base({
      'GET /api/c/acme/claims': () => {
        claimReads += 1
        return { body: claimReads === 1 ? pendingClaims : { items: [] } }
      },
      'PATCH /api/c/acme/players/p1/claims/cl1': () => ({
        body: { claimId: 'cl1', status: 'approved' },
      }),
    })

    renderAt('/c/acme/settings')

    expect(await screen.findByText('Sari')).toBeInTheDocument()
    expect(
      screen.getByText(t('admin.claims.claimant', { name: 'Citra' })),
    ).toBeInTheDocument()
    expect(screen.getByText('2026-11-03')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: t('admin.claims.approve') }))

    await waitFor(() => {
      const call = fetchMock.mock.calls.find(
        ([url, init]) =>
          String(url) === '/api/c/acme/players/p1/claims/cl1' &&
          (init as RequestInit | undefined)?.method === 'PATCH',
      )
      expect(jsonBody((call as [string, RequestInit])[1])).toEqual({
        decision: 'approve',
      })
    })
    await waitFor(() => {
      expect(screen.queryByText('Sari')).not.toBeInTheDocument()
    })
  })

  it('says when no claim is waiting', async () => {
    base({})

    renderAt('/c/acme/settings')

    expect(await screen.findByText(t('admin.claims.empty'))).toBeInTheDocument()
  })
})
