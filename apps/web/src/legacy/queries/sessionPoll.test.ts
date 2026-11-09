import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { vi } from 'vitest'
import { mockFetch } from '../../test/fetchMock'
import { getSession, setCommunitySlug } from './endpoints'

const detail = {
  id: 's1',
  title: 'Tuesday',
  date: '2026-11-03',
  startTime: '19:00',
  slotMinutes: 15,
  status: 'draft',
  version: 7,
  participants: [],
  games: [],
}

function ifNoneMatch(init: RequestInit | undefined): string | undefined {
  return (init?.headers as Record<string, string> | undefined)?.['If-None-Match']
}

describe('session poll', () => {
  beforeEach(() => {
    setCommunitySlug('majadu')
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('asks with the last ETag and keeps the snapshot on a 304', async () => {
    let sessionCalls = 0
    mockFetch({
      'GET /api/c/majadu/sessions/s1': (init) => {
        sessionCalls += 1
        if (sessionCalls === 1) return { body: detail, headers: { ETag: '"7"' } }
        expect(ifNoneMatch(init)).toBe('"7"')
        return { status: 304 }
      },
    })

    const first = await getSession('s1')
    expect(first?.version).toBe(7)

    const second = await getSession('s1', undefined, () => first)
    expect(second).toBe(first)
    expect(sessionCalls).toBe(2)
  })

  it('re-reads unconditionally when a 304 arrives with nothing cached', async () => {
    let sessionCalls = 0
    mockFetch({
      'GET /api/c/majadu/sessions/s1': (init) => {
        sessionCalls += 1
        if (sessionCalls === 1) return { body: detail, headers: { ETag: '"7"' } }
        if (sessionCalls === 2) return { status: 304 }
        expect(ifNoneMatch(init)).toBeUndefined()
        return { body: { ...detail, version: 8 }, headers: { ETag: '"8"' } }
      },
    })

    await getSession('s1')
    const recovered = await getSession('s1', undefined, () => null)
    expect(recovered?.version).toBe(8)
    expect(sessionCalls).toBe(3)
  })

  it('turns a schedule side into a fixed pair and joins players in the given order', async () => {
    mockFetch({
      'GET /api/c/majadu/sessions/s1': () => ({
        body: {
          ...detail,
          participants: [
            { playerId: 'p1', name: 'Arya', absent: false },
            { playerId: 'p2', name: 'Bima', absent: false },
          ],
          games: [
            {
              round: 0,
              court: 0,
              sideA: ['p2'],
              sideB: [],
              scoreA: null,
              scoreB: null,
              status: 'scheduled',
            },
          ],
        },
      }),
    })

    const snapshot = await getSession('s1')
    // A half-filled side keeps its one player and an empty second slot; the
    // schedule type is a tuple, so the shape never grows past two.
    expect(snapshot?.schedule[0].teamA).toEqual(['p2', ''])
    expect(snapshot?.schedule[0].teamB).toEqual(['', ''])
    expect(snapshot?.players.map((player) => player.id)).toEqual(['p1', 'p2'])
  })
})