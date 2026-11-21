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

const archivePlayer = { ...playerA, id: 'p-f', name: 'Fitri', gender: 'F', tier: 'A' }

const sessionDetail = (version = 3) => ({
  id: 's1',
  title: 'Sunday',
  date: '2026-11-08',
  startTime: '09:00',
  slotMinutes: 30,
  status: 'draft',
  version,
  participants: [{ playerId: archivePlayer.id, name: archivePlayer.name, absent: false }],
  games: [],
})

describe('roster read', () => {
  beforeEach(() => {
    window.history.replaceState({}, '', '/c/a')
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  // REL-FE-02: the read used to stamp an empty roster when it failed, which
  // answered every later read for the life of the tab: the join then fell back
  // to `gender 'M'` / `tier 2` for every player until the community changed.
  it('retries the roster after a failed read instead of remembering it as empty', async () => {
    const { getSession, setCommunitySlug } = await loadEndpoints()
    setCommunitySlug('a')
    let rosterCalls = 0
    mockFetch({
      'GET /api/c/a/sessions/s1': () => ({ body: sessionDetail() }),
      'GET /api/c/a/players?limit=1000': () => {
        rosterCalls += 1
        // 403 is not retried by the transport, so this is exactly one failure.
        return rosterCalls === 1 ? { status: 403, body: {} } : { body: { items: [archivePlayer] } }
      },
    })

    const failed = await getSession('s1')
    expect(rosterCalls).toBe(1)
    // The failed read left the roster unknown, so the join used its defaults:
    // every player reads as male tier 2, which is the wrong grade and the wrong
    // mixed-double grouping.
    expect(failed?.players[0]).toMatchObject({ gender: 'M', tier: 2 })

    const retried = await getSession('s1')
    expect(rosterCalls).toBe(2)
    // The retry reached the server and the real gender/tier came through.
    expect(retried?.players[0]).toMatchObject({ gender: 'F', tier: 7 })
  })

  // REL-FE-06: the shared read used to carry the first caller's signal, so
  // navigating away cancelled the roster for everyone still on the page.
  it('starts the shared roster read without the first caller signal', async () => {
    const { listPlayers, setCommunitySlug } = await loadEndpoints()
    setCommunitySlug('a')
    const signals: Array<AbortSignal | null | undefined> = []
    mockFetch({
      'GET /api/c/a/players?limit=1000': (init) => {
        signals.push(init?.signal)
        return { body: { items: [playerA] } }
      },
    })

    const controller = new AbortController()
    const first = listPlayers(controller.signal)
    const second = listPlayers()
    controller.abort()

    await expect(Promise.all([first, second])).resolves.toEqual([
      [expect.objectContaining({ playerId: 'p-a' })],
      [expect.objectContaining({ playerId: 'p-a' })],
    ])
    // The transport supplies its own timeout signal; the point is that the one
    // it carries is not the caller's, so the caller's abort never reaches it.
    expect(signals).toHaveLength(1)
    expect(signals[0]).not.toBe(controller.signal)
    expect(signals[0]?.aborted).toBe(false)
  })

  // REL-FE-07: the server clamps `limit` to `api.page_size_max` (500), so one
  // request silently dropped every player past it.
  it('follows the cursor past the server page cap', async () => {
    const { listPlayers, setCommunitySlug } = await loadEndpoints()
    setCommunitySlug('a')
    const roster = Array.from({ length: 520 }, (_, index) => ({
      ...playerA,
      id: `p-${String(index).padStart(3, '0')}`,
      name: `Player ${index}`,
    }))
    const cursor = roster[499].id
    let calls = 0
    mockFetch({
      'GET /api/c/a/players?limit=1000': () => {
        calls += 1
        return { body: { items: roster.slice(0, 500) } }
      },
      [`GET /api/c/a/players?limit=1000&cursor=${cursor}`]: () => {
        calls += 1
        return { body: { items: roster.slice(500) } }
      },
    })

    const rows = await listPlayers()
    expect(rows).toHaveLength(520)
    expect(rows[519].name).toBe('Player 519')
    expect(calls).toBe(2)
  })
})