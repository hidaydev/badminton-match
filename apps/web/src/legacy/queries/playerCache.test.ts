import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mockFetch } from '../../test/fetchMock'

// Same name, different players: the roster of one community must never answer
// a lookup issued for another.
const playerA = {
  id: 'p-a',
  name: 'Andi',
  gender: 'M',
  tier: 'B',
  userId: null,
  createdAt: '2026-01-01T00:00:00Z',
  updatedAt: '2026-01-01T00:00:00Z',
}
const playerB = { ...playerA, id: 'p-b', tier: 'C' }

function statsOf(player: typeof playerA) {
  return {
    playerId: player.id,
    name: player.name,
    tier: player.tier,
    gender: player.gender,
    points: 0,
    games: 0,
    wins: 0,
    losses: 0,
  }
}

async function loadEndpoints() {
  // Module-level caches survive between tests otherwise; a fresh registry makes
  // each case start from the same state.
  vi.resetModules()
  return await import('./endpoints')
}

describe('player cache across communities', () => {
  beforeEach(() => {
    window.history.replaceState({}, '', '/c/a')
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('does not resolve a roster name from the previous community', async () => {
    const { listPlayers, setCommunitySlug, getPlayerStatsRaw } = await loadEndpoints()
    setCommunitySlug('a')
    mockFetch({
      'GET /api/c/a/players?limit=1000': () => ({ body: { items: [playerA] } }),
      'GET /api/c/b/players?limit=100&q=Andi': () => ({ body: { items: [playerB] } }),
      'GET /api/c/b/players/p-b/stats': () => ({ body: statsOf(playerB) }),
    })

    await listPlayers()

    // A switch changes the URL before the shell effect publishes the new slug.
    // The roster cache must not answer with A's rows in that window.
    window.history.replaceState({}, '', '/c/b')

    const result = await getPlayerStatsRaw('Andi')
    expect(result.playerId).toBe('p-b')
    expect(result.tier).toBe('C')
  })

  it('forgets a name resolved in the previous community', async () => {
    const { setCommunitySlug, getPlayerStatsRaw, knownPlayerId } = await loadEndpoints()
    setCommunitySlug('a')
    mockFetch({
      'GET /api/c/a/players?limit=100&q=Andi': () => ({ body: { items: [playerA] } }),
      'GET /api/c/a/players/p-a/stats': () => ({ body: statsOf(playerA) }),
    })

    await getPlayerStatsRaw('Andi')
    expect(knownPlayerId('Andi')).toBe('p-a')

    window.history.replaceState({}, '', '/c/b')
    expect(knownPlayerId('Andi')).toBeNull()
  })
})