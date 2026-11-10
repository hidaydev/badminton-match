import { describe, expect, it } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import App from '../../App'
import type { Membership } from '../../auth/api'
import { t } from '../../i18n'
import { jsonBody, mockFetch } from '../../test/fetchMock'

const sessionUser = { id: 'u1', displayName: 'Ada', platformOwner: false }

const ani = {
  id: 'p1',
  name: 'Ani',
  gender: 'F',
  tier: 'C',
  userId: null,
  createdAt: '2026-11-01 10:00:00+07',
  updatedAt: '2026-11-01 10:00:00+07',
  aliases: [],
}

const pendingClaim = {
  id: 'c1',
  userId: 'u9',
  status: 'pending',
  decidedBy: '',
  decidedAt: '',
  reason: '',
  createdAt: '2026-11-02 09:00:00+07',
}

function renderAt(path: string) {
  window.history.replaceState({}, '', path)
  return render(<App />)
}

function membership(role: Membership['role']): Membership {
  return { id: 'c1', slug: 'acme', name: 'Acme', role }
}

describe('players', () => {
  it('a member sees the list and asks to claim a player', async () => {
    const fetchMock = mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [membership('member')] } }),
      'GET /api/c/acme/players?limit=50': () => ({ body: { items: [ani] } }),
      'GET /api/c/acme/players/p1': () => ({ body: ani }),
      'GET /api/c/acme/players/p1/claims': () => ({ body: { items: [] } }),
      'POST /api/c/acme/players/p1/claims': () => ({
        status: 201,
        body: { playerId: 'p1', status: 'pending' },
      }),
    })

    renderAt('/c/acme/players')

    fireEvent.click(await screen.findByRole('link', { name: /Ani/ }))
    fireEvent.click(await screen.findByRole('button', { name: t('playerAdmin.claim') }))

    await waitFor(() => {
      const call = fetchMock.mock.calls.find(
        ([url, init]) =>
          String(url) === '/api/c/acme/players/p1/claims' &&
          (init as RequestInit | undefined)?.method === 'POST',
      )
      expect(call?.[0]).toBe('/api/c/acme/players/p1/claims')
    })
    // A member never gets the roster form.
    expect(screen.queryByRole('button', { name: t('players.add.submit') })).toBeNull()
  })

  it('an admin can page past the first 50 players when picking a merge source', async () => {
    const roster = Array.from({ length: 50 }, (_, index) => ({
      ...ani,
      id: `p${index + 1}`,
      name: `Player ${index + 1}`,
    }))
    const extra = { ...ani, id: 'p51', name: 'Player 51' }
    const fetchMock = mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [membership('admin')] } }),
      'GET /api/c/acme/players?limit=50': () => ({ body: { items: roster } }),
      'GET /api/c/acme/players?cursor=p50&limit=50': () => ({ body: { items: [extra] } }),
      'GET /api/c/acme/players/p1': () => ({ body: roster[0] }),
      'GET /api/c/acme/players/p1/claims': () => ({ body: { items: [] } }),
    })

    renderAt('/c/acme/players/p1')

    expect(await screen.findByRole('option', { name: 'Player 50' })).toBeInTheDocument()
    expect(screen.queryByRole('option', { name: 'Player 51' })).toBeNull()

    fireEvent.click(screen.getByRole('button', { name: t('players.loadMore') }))

    expect(await screen.findByRole('option', { name: 'Player 51' })).toBeInTheDocument()
    expect(
      fetchMock.mock.calls.some(([url]) =>
        String(url).includes('/players?cursor=p50&limit=50'),
      ),
    ).toBe(true)
  })

  it('a host adds a player with its grade and aliases', async () => {
    const fetchMock = mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [membership('host')] } }),
      'GET /api/c/acme/players?limit=50': () => ({ body: { items: [] } }),
      'POST /api/c/acme/players': () => ({ status: 201, body: { ...ani, name: 'Dewi' } }),
    })

    renderAt('/c/acme/players')

    fireEvent.change(await screen.findByLabelText(t('players.add.name')), {
      target: { value: 'Dewi' },
    })
    fireEvent.change(screen.getByLabelText(t('players.add.tier')), {
      target: { value: 'C' },
    })
    fireEvent.change(screen.getByLabelText(t('players.add.aliases')), {
      target: { value: 'D, Dew' },
    })
    fireEvent.click(screen.getByRole('button', { name: t('players.add.submit') }))

    await waitFor(() => {
      const call = fetchMock.mock.calls.find(
        ([url, init]) =>
          String(url) === '/api/c/acme/players' &&
          (init as RequestInit | undefined)?.method === 'POST',
      )
      expect(call?.[0]).toBe('/api/c/acme/players')
      expect(jsonBody((call as [string, RequestInit])[1])).toEqual({
        name: 'Dewi',
        gender: 'M',
        tier: 'C',
        aliases: ['D', 'Dew'],
      })
    })
  })

  it('keeps the roster form closed until its summary or the empty state opens it', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [membership('host')] } }),
      'GET /api/c/acme/players?limit=50': () => ({ body: { items: [] } }),
    })

    renderAt('/c/acme/players')

    const name = await screen.findByLabelText(t('players.add.name'))
    const panel = name.closest('details')
    if (!(panel instanceof HTMLDetailsElement)) {
      throw new Error('the roster form is not a disclosure element')
    }
    expect(panel.open).toBe(false)

    const summary = screen.getByText(t('players.add'), { selector: 'summary' })
    fireEvent.click(summary)
    expect(panel.open).toBe(true)
    fireEvent.click(summary)
    expect(panel.open).toBe(false)

    // The empty state offers the same panel, so its button has to open it; a
    // plain anchor would scroll to a closed box and look broken.
    await screen.findByText(t('players.empty'))
    fireEvent.click(screen.getByRole('button', { name: t('players.add') }))
    expect(panel.open).toBe(true)
  })

  it('an admin decides a pending claim', async () => {
    const fetchMock = mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [membership('admin')] } }),
      'GET /api/c/acme/players?limit=50': () => ({ body: { items: [ani] } }),
      'GET /api/c/acme/players/p1': () => ({ body: ani }),
      'GET /api/c/acme/players/p1/claims': () => ({ body: { items: [pendingClaim] } }),
      'PATCH /api/c/acme/players/p1/claims/c1': () => ({
        body: { claimId: 'c1', status: 'approved' },
      }),
    })

    renderAt('/c/acme/players/p1')

    fireEvent.click(
      await screen.findByRole('button', { name: t('playerAdmin.decide.approve') }),
    )

    await waitFor(() => {
      const call = fetchMock.mock.calls.find(
        ([url, init]) =>
          String(url) === '/api/c/acme/players/p1/claims/c1' &&
          (init as RequestInit | undefined)?.method === 'PATCH',
      )
      expect(call?.[0]).toBe('/api/c/acme/players/p1/claims/c1')
      expect(jsonBody((call as [string, RequestInit])[1])).toEqual({ decision: 'approve' })
    })
  })

  it('hides the claim action when the viewer already owns a player', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [membership('member')] } }),
      'GET /api/c/acme/players/p1': () => ({
        body: { ...ani, viewerOwnsPlayer: true },
      }),
      'GET /api/c/acme/players/p1/claims': () => ({ body: { items: [] } }),
    })

    renderAt('/c/acme/players/p1')

    expect(await screen.findByRole('heading', { name: 'Ani' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: t('playerAdmin.claim') })).toBeNull()
  })

  it('offers the claim action to a viewer who owns no player', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [membership('member')] } }),
      'GET /api/c/acme/players/p1': () => ({
        body: { ...ani, viewerOwnsPlayer: false },
      }),
      'GET /api/c/acme/players/p1/claims': () => ({ body: { items: [] } }),
    })

    renderAt('/c/acme/players/p1')

    expect(
      await screen.findByRole('button', { name: t('playerAdmin.claim') }),
    ).toBeInTheDocument()
  })

  it('hides the claim action on a player that already has an owner', async () => {
    mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [membership('member')] } }),
      'GET /api/c/acme/players/p1': () => ({
        body: { ...ani, userId: 'u9', viewerOwnsPlayer: false },
      }),
      'GET /api/c/acme/players/p1/claims': () => ({ body: { items: [] } }),
    })

    renderAt('/c/acme/players/p1')

    expect(await screen.findByRole('heading', { name: 'Ani' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: t('playerAdmin.claim') })).toBeNull()
  })

  it('searches while typing, without pressing Find', async () => {
    const anita = { ...ani, id: 'p2', name: 'Anita' }
    mockFetch({
      'GET /api/auth/me': () => ({ body: sessionUser }),
      'GET /api/communities': () => ({ body: { items: [membership('member')] } }),
      'GET /api/c/acme/players?limit=50': () => ({ body: { items: [ani] } }),
      'GET /api/c/acme/players?q=Ani&limit=50': () => ({ body: { items: [anita] } }),
    })

    renderAt('/c/acme/players')

    const search = await screen.findByLabelText(t('players.search'))
    fireEvent.change(search, { target: { value: 'Ani' } })

    expect(await screen.findByRole('link', { name: /Anita/ })).toBeInTheDocument()
    expect(window.location.search).toBe('?q=Ani')
  })
})
