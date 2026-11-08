import { describe, expect, it } from 'vitest'
import { jsonBody, mockFetch } from '../../test/fetchMock'
import {
  claimPlayer,
  createPlayer,
  decideClaim,
  deletePlayer,
  getMyPlayer,
  getPlayer,
  listClaims,
  listPlayers,
  mergePlayers,
  PLAYER_PAGE,
  releaseOwnClaim,
  updatePlayer,
} from '../api'
import type { Player, PlayerClaim, MergeResult } from '../api'

const ani: Player = {
  id: 'p1',
  name: 'Ani',
  gender: 'F',
  tier: 'C',
  userId: null,
  createdAt: '2026-11-01 10:00:00+07',
  updatedAt: '2026-11-01 10:00:00+07',
  aliases: [],
}

const claim: PlayerClaim = {
  id: 'c1',
  userId: 'u9',
  status: 'pending',
  decidedBy: '',
  decidedAt: '',
  reason: '',
  createdAt: '2026-11-02 09:00:00+07',
}

const mergeResult: MergeResult = {
  targetPlayerId: 'p1',
  sourcePlayerId: 'p2',
  aliasesMoved: 2,
  claimsMoved: 1,
  deltasMoved: 0,
  snapshotsMoved: 3,
  achievementsMoved: 0,
  pairsMoved: 4,
  ratingStateMoved: 1,
}

describe('listPlayers', () => {
  it('sends limit=50 when the caller sets no page size and omits the empty filters', async () => {
    const fetchMock = mockFetch({
      'GET /api/c/acme/players?limit=50': () => ({ body: { items: [ani] } }),
    })

    const rows = await listPlayers('acme')

    expect(rows).toEqual([ani])
    expect(PLAYER_PAGE).toBe(50)
    expect(fetchMock.mock.calls[0][0]).toBe('/api/c/acme/players?limit=50')
  })

  it('sends q, tier, cursor and the caller page size when they are set', async () => {
    const fetchMock = mockFetch({
      'GET /api/c/acme/players?q=an&tier=C%2B&cursor=p9&limit=20': () => ({
        body: { items: [ani] },
      }),
    })

    await listPlayers('acme', { q: 'an', tier: 'C+', cursor: 'p9', limit: 20 })

    expect(fetchMock.mock.calls[0][0]).toBe(
      '/api/c/acme/players?q=an&tier=C%2B&cursor=p9&limit=20',
    )
  })

  it('omits an empty q and null tier and cursor', async () => {
    const fetchMock = mockFetch({
      'GET /api/c/acme/players?limit=50': () => ({ body: { items: [] } }),
    })

    await listPlayers('acme', { q: '', tier: null, cursor: null })

    expect(fetchMock.mock.calls[0][0]).toBe('/api/c/acme/players?limit=50')
  })
})

describe('getPlayer', () => {
  it('percent-encodes the slug and the player id in the path', async () => {
    const fetchMock = mockFetch({
      'GET /api/c/acme%20team/players/p%201': () => ({ body: ani }),
    })

    await expect(getPlayer('acme team', 'p 1')).resolves.toEqual(ani)
    expect(fetchMock.mock.calls[0][0]).toBe('/api/c/acme%20team/players/p%201')
  })
})

describe('getMyPlayer', () => {
  it('returns the first row of the mine list', async () => {
    const fetchMock = mockFetch({
      'GET /api/c/acme/players?mine=1': () => ({ body: { items: [ani] } }),
    })

    await expect(getMyPlayer('acme')).resolves.toEqual(ani)
    expect(fetchMock.mock.calls[0][0]).toBe('/api/c/acme/players?mine=1')
  })

  it('returns null when the account has no approved claim', async () => {
    mockFetch({ 'GET /api/c/acme/players?mine=1': () => ({ body: { items: [] } }) })

    await expect(getMyPlayer('acme')).resolves.toBeNull()
  })
})

describe('claimPlayer', () => {
  it('posts to the player claims route and returns the server status', async () => {
    const fetchMock = mockFetch({
      'POST /api/c/acme/players/p1/claims': () => ({
        status: 201,
        body: { playerId: 'p1', status: 'pending' },
      }),
    })

    const result = await claimPlayer('acme', 'p1')

    expect(result).toEqual({ playerId: 'p1', status: 'pending' })
    expect(fetchMock.mock.calls[0][0]).toBe('/api/c/acme/players/p1/claims')
    expect(fetchMock.mock.calls[0][1]?.method).toBe('POST')
  })
})

describe('decideClaim', () => {
  it('patches the claim route with the approve decision and its reason', async () => {
    const fetchMock = mockFetch({
      'PATCH /api/c/acme/players/p1/claims/c1': () => ({
        body: { claimId: 'c1', status: 'approved' },
      }),
    })

    const result = await decideClaim('acme', 'p1', 'c1', {
      decision: 'approve',
      reason: 'known player',
    })

    expect(result).toEqual({ claimId: 'c1', status: 'approved' })
    expect(fetchMock.mock.calls[0][1]?.method).toBe('PATCH')
    expect(jsonBody(fetchMock.mock.calls[0][1])).toEqual({
      decision: 'approve',
      reason: 'known player',
    })
  })

  it('patches the release action instead of a decision', async () => {
    const fetchMock = mockFetch({
      'PATCH /api/c/acme/players/p1/claims/c1': () => ({
        body: { claimId: 'c1', status: 'released' },
      }),
    })

    await decideClaim('acme', 'p1', 'c1', { action: 'release', reason: 'moved away' })

    expect(jsonBody(fetchMock.mock.calls[0][1])).toEqual({
      action: 'release',
      reason: 'moved away',
    })
  })
})

describe('mergePlayers', () => {
  it('posts the source id to the target merge route and returns the moved counts', async () => {
    const fetchMock = mockFetch({
      'POST /api/c/acme/players/p1/merge': () => ({ body: mergeResult }),
    })

    const result = await mergePlayers('acme', 'p1', 'p2')

    expect(result).toEqual(mergeResult)
    expect(fetchMock.mock.calls[0][0]).toBe('/api/c/acme/players/p1/merge')
    expect(jsonBody(fetchMock.mock.calls[0][1])).toEqual({ sourcePlayerId: 'p2' })
  })
})

describe('listClaims', () => {
  it('returns the claim rows for one player', async () => {
    mockFetch({
      'GET /api/c/acme/players/p1/claims': () => ({ body: { items: [claim] } }),
    })

    await expect(listClaims('acme', 'p1')).resolves.toEqual([claim])
  })
})

describe('releaseOwnClaim', () => {
  it('deletes the caller own claim route', async () => {
    const fetchMock = mockFetch({
      'DELETE /api/c/acme/players/p1/claim': () => ({
        body: { claimId: 'c1', status: 'released' },
      }),
    })

    await expect(releaseOwnClaim('acme', 'p1')).resolves.toEqual({
      claimId: 'c1',
      status: 'released',
    })
    expect(fetchMock.mock.calls[0][1]?.method).toBe('DELETE')
  })
})

describe('player writes', () => {
  it('creates with a post that carries the new player fields', async () => {
    const fetchMock = mockFetch({
      'POST /api/c/acme/players': () => ({ status: 201, body: ani }),
    })

    await createPlayer('acme', { name: 'Ani', gender: 'F', tier: 'C', aliases: ['Ani'] })

    expect(jsonBody(fetchMock.mock.calls[0][1])).toEqual({
      name: 'Ani',
      gender: 'F',
      tier: 'C',
      aliases: ['Ani'],
    })
  })

  it('updates with a patch that carries the changed fields', async () => {
    const fetchMock = mockFetch({
      'PATCH /api/c/acme/players/p1': () => ({ body: ani }),
    })

    await updatePlayer('acme', 'p1', { tier: null })

    expect(fetchMock.mock.calls[0][1]?.method).toBe('PATCH')
    expect(jsonBody(fetchMock.mock.calls[0][1])).toEqual({ tier: null })
  })

  it('deletes with a delete that resolves without a body', async () => {
    const fetchMock = mockFetch({
      'DELETE /api/c/acme/players/p1': () => ({ status: 204 }),
    })

    await expect(deletePlayer('acme', 'p1')).resolves.toBeUndefined()
    expect(fetchMock.mock.calls[0][1]?.method).toBe('DELETE')
  })

  it('throws the server code and detail when the write is refused', async () => {
    mockFetch({
      'PATCH /api/c/acme/players/p1': () => ({
        status: 409,
        body: { code: 'CONFLICT', detail: 'still has matches' },
      }),
    })

    await expect(updatePlayer('acme', 'p1', { name: 'Ani' })).rejects.toMatchObject({
      status: 409,
      code: 'CONFLICT',
      detail: 'still has matches',
    })
  })
})