import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { jsonBody, mockFetch } from '../../test/fetchMock'
import { patchGameScore, publishSession, swapMembers } from './endpoints'
import { ApiError } from './retry'
import { toGameKey, toPlayerId, toTimeString } from '../types'
import type { CloudSnapshot, Player, ScheduleSlot, SessionConfig, SessionScoring } from '../types'

const uuid = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`
const ary = uuid(1)
const bowo = uuid(2)
const candra = uuid(3)
const dika = uuid(4)
const zaki = uuid(9)

const scoring = (gamesToWin = 1): SessionScoring => ({
  preset: 'custom',
  label: 'Custom',
  gamesToWin,
  pointsToWin: 21,
  winBy: 2,
  maxPoints: 30,
  deuceAt: 20,
  changeEndsAt: null,
})

const sessionConfig = (rules: SessionScoring): SessionConfig => ({
  title: 'Sunday',
  date: '2026-11-08',
  courts: 2,
  sessionStart: toTimeString('09:00'),
  slotMinutes: 30,
  courtTimes: [{ start: toTimeString('09:00'), end: toTimeString('10:00') }],
  playerCount: 4,
  courtNames: [],
  locked: false,
  scoring: rules,
})

const player = (id: string, name: string): Player => ({
  id: toPlayerId(id),
  name,
  gender: 'M',
  tier: 4,
})

const defaultPlayers = [player(ary, 'Arya'), player(bowo, 'Bowo'), player(candra, 'Candra'), player(dika, 'Dika')]

/** The name lookups resolveSnapshotPlayers performs against the roster. */
const rosterRoutes: Record<string, () => { body: unknown }> = {
  'GET /api/c/plan/players?limit=100&q=Arya': () => ({ body: { items: [{ id: ary, name: 'Arya' }] } }),
  'GET /api/c/plan/players?limit=100&q=Bowo': () => ({ body: { items: [{ id: bowo, name: 'Bowo' }] } }),
  'GET /api/c/plan/players?limit=100&q=Candra': () => ({ body: { items: [{ id: candra, name: 'Candra' }] } }),
  'GET /api/c/plan/players?limit=100&q=Dika': () => ({ body: { items: [{ id: dika, name: 'Dika' }] } }),
}

const slot = (court: number, teamA: [string, string], teamB: [string, string]): ScheduleSlot => ({
  slot: 0,
  court,
  teamA: [toPlayerId(teamA[0]), toPlayerId(teamA[1])],
  teamB: [toPlayerId(teamB[0]), toPlayerId(teamB[1])],
})

const snapshot = (overrides: Partial<CloudSnapshot> = {}): CloudSnapshot => ({
  version: 9,
  session: sessionConfig(scoring(1)),
  players: defaultPlayers,
  fixMatches: [],
  schedule: [slot(0, [ary, bowo], [candra, dika])],
  playedGames: [],
  gameScores: {},
  ...overrides,
})

type WireGame = {
  round: number
  court: number
  sideA: string[]
  sideB: string[]
  scoreA: number | null
  scoreB: number | null
  sets?: Array<{ a: number; b: number }>
  status: string
}

const wire = (games: WireGame[] = [], overrides: Record<string, unknown> = {}) => ({
  id: 's1',
  title: 'Sunday',
  date: '2026-11-08',
  startTime: '09:00',
  slotMinutes: 30,
  status: 'draft',
  version: 5,
  participants: [
    { playerId: ary, name: 'Arya', absent: false },
    { playerId: bowo, name: 'Bowo', absent: false },
    { playerId: candra, name: 'Candra', absent: false },
    { playerId: dika, name: 'Dika', absent: false },
  ],
  games,
  scoring: scoring(1),
  ...overrides,
})

const schedulingGame = (status = 'scheduled', scoreA: number | null = null): WireGame => ({
  round: 0,
  court: 0,
  sideA: [ary, bowo],
  sideB: [candra, dika],
  scoreA,
  scoreB: scoreA === null ? null : 19,
  status,
})

type FetchMock = ReturnType<typeof mockFetch>

type RecordedCall = {
  method: string
  url: string
  headers: Record<string, string>
  body: unknown
}

const calls = (fetchMock: FetchMock): RecordedCall[] =>
  fetchMock.mock.calls.map(([input, init]) => ({
    method: init?.method ?? 'GET',
    url: String(input),
    headers: (init?.headers ?? {}) as unknown as Record<string, string>,
    body: jsonBody(init),
  }))

const sequence = (fetchMock: FetchMock) => calls(fetchMock).map((call) => `${call.method} ${call.url}`)
const writes = (fetchMock: FetchMock) =>
  calls(fetchMock).filter((call) => call.method !== 'GET')

beforeEach(() => {
  window.history.replaceState({}, '', '/c/plan')
})

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('publishSession', () => {
  it('takes If-Match from the held snapshot and moves each returned version forward', async () => {
    const fetchMock = mockFetch({
      ...rosterRoutes,
      'GET /api/c/plan/sessions/s1': () => ({ body: wire([schedulingGame()]) }),
      'PATCH /api/c/plan/sessions/s1': () => ({ body: { version: 10 } }),
      'PUT /api/c/plan/sessions/s1/schedule': () => ({ body: { version: 11 } }),
      'PATCH /api/c/plan/sessions/s1/games/0-0': () => ({ body: { version: 12 } }),
    })

    const saved = await publishSession(
      's1',
      snapshot({ gameScores: { [toGameKey(0, 0)]: { a: 21, b: 19 } } }),
    )

    expect(sequence(fetchMock)).toEqual([
      'GET /api/c/plan/sessions/s1',
      'GET /api/c/plan/players?limit=100&q=Arya',
      'GET /api/c/plan/players?limit=100&q=Bowo',
      'GET /api/c/plan/players?limit=100&q=Candra',
      'GET /api/c/plan/players?limit=100&q=Dika',
      'PATCH /api/c/plan/sessions/s1',
      'PUT /api/c/plan/sessions/s1/schedule',
      'GET /api/c/plan/sessions/s1',
      'PATCH /api/c/plan/sessions/s1/games/0-0',
      'GET /api/c/plan/sessions/s1',
    ])

    const [, , , , , recordPatch, schedulePut, , gamePatch] = calls(fetchMock)

    // The record PATCH must start from the snapshot's version (9), not the
    // version read from the server (5).
    expect(recordPatch.headers['If-Match']).toBe('"9"')
    expect(schedulePut.headers['If-Match']).toBe('"10"')
    expect(gamePatch.headers['If-Match']).toBe('"11"')

    expect(recordPatch.body).toEqual({
      title: 'Sunday',
      date: '2026-11-08',
      startTime: '09:00',
      slotMinutes: 30,
    })
    expect(schedulePut.body).toEqual({
      games: [{ round: 0, court: 0, sideA: [ary, bowo], sideB: [candra, dika] }],
    })
    expect(gamePatch.body).toEqual({ scoreA: 21, scoreB: 19 })

    // Only the record write is an idempotent create-style request.
    expect(recordPatch.headers['Idempotency-Key']).toMatch(/\S/)
    expect(schedulePut.headers).not.toHaveProperty('Idempotency-Key')
    expect(gamePatch.headers).not.toHaveProperty('Idempotency-Key')

    expect(saved.version).toBe(5)
    expect(saved.schedule).toEqual([slot(0, [ary, bowo], [candra, dika])])
  })

  it('sends no game write when the server already holds the wanted sets and status', async () => {
    const playedGame: WireGame = {
      ...schedulingGame('played', 42),
      sets: [{ a: 21, b: 19 }, { a: 21, b: 19 }],
    }
    const fetchMock = mockFetch({
      ...rosterRoutes,
      'GET /api/c/plan/sessions/s1': () => ({
        body: wire([
          playedGame,
          { ...schedulingGame(), court: 1, sideA: [ary, candra], sideB: [bowo, dika] },
        ]),
      }),
      'PATCH /api/c/plan/sessions/s1': () => ({ body: { version: 10 } }),
      'PUT /api/c/plan/sessions/s1/schedule': () => ({ body: { version: 11 } }),
    })

    await publishSession(
      's1',
      snapshot({
        schedule: [
          slot(0, [ary, bowo], [candra, dika]),
          slot(1, [ary, candra], [bowo, dika]),
        ],
        gameScores: {
          [toGameKey(0, 0)]: { a: 42, b: 38, sets: [{ a: 21, b: 19 }, { a: 21, b: 19 }] },
        },
        playedGames: [toGameKey(0, 0)],
      }),
    )

    expect(sequence(fetchMock).filter((call) => call.includes('/games/'))).toEqual([])
  })

  it('writes the played flag when the server disagrees with the snapshot', async () => {
    const fetchMock = mockFetch({
      ...rosterRoutes,
      'GET /api/c/plan/sessions/s1': () => ({
        body: wire([
          schedulingGame('scheduled'),
          {
            ...schedulingGame('played', 21),
            court: 1,
            sets: [{ a: 21, b: 19 }],
            sideA: [ary, candra],
            sideB: [bowo, dika],
          },
        ]),
      }),
      'PATCH /api/c/plan/sessions/s1': () => ({ body: { version: 10 } }),
      'PUT /api/c/plan/sessions/s1/schedule': () => ({ body: { version: 11 } }),
      'PATCH /api/c/plan/sessions/s1/games/0-0': () => ({ body: { version: 12 } }),
      'PATCH /api/c/plan/sessions/s1/games/0-1': () => ({ body: { version: 13 } }),
    })

    await publishSession(
      's1',
      snapshot({
        schedule: [
          slot(0, [ary, bowo], [candra, dika]),
          slot(1, [ary, candra], [bowo, dika]),
        ],
        playedGames: [toGameKey(0, 0)],
      }),
    )

    const gameWrites = writes(fetchMock).filter((call) => call.url.includes('/games/'))

    expect(gameWrites.map((call) => call.body)).toEqual([{ played: true }, { played: false }])
    expect(gameWrites.map((call) => call.headers['If-Match'])).toEqual(['"11"', '"12"'])
  })

  it('drops a placeholder name from the scheduled side', async () => {
    const fetchMock = mockFetch({
      ...rosterRoutes,
      'GET /api/c/plan/sessions/s1': () => ({ body: wire() }),
      'PATCH /api/c/plan/sessions/s1': () => ({ body: { version: 10 } }),
      'PUT /api/c/plan/sessions/s1/schedule': () => ({ body: { version: 11 } }),
    })

    await publishSession(
      's1',
      snapshot({
        players: [player('local-tbd', 'free 1'), ...defaultPlayers.slice(1)],
        schedule: [slot(0, ['local-tbd', bowo], [candra, dika])],
      }),
    )

    const schedulePut = writes(fetchMock).find((call) => call.method === 'PUT')
    expect(schedulePut?.body).toEqual({
      games: [{ round: 0, court: 0, sideA: [bowo], sideB: [candra, dika] }],
    })
    expect(sequence(fetchMock).some((call) => call.includes('free'))).toBe(false)
  })

  it('creates one player for an unknown name and uses the returned id in the schedule', async () => {
    const fetchMock = mockFetch({
      ...rosterRoutes,
      'GET /api/c/plan/sessions/s1': () => ({ body: wire() }),
      'GET /api/c/plan/players?limit=100&q=Zaki%20Baru': () => ({ body: { items: [] } }),
      'POST /api/c/plan/players': () => ({
        body: {
          id: zaki,
          name: 'Zaki Baru',
          gender: 'M',
          tier: null,
          userId: null,
          createdAt: '2026-11-08T00:00:00Z',
          updatedAt: '2026-11-08T00:00:00Z',
        },
      }),
      'PATCH /api/c/plan/sessions/s1': () => ({ body: { version: 10 } }),
      'PUT /api/c/plan/sessions/s1/schedule': () => ({ body: { version: 11 } }),
    })

    const newcomer = player('local-zaki', 'Zaki Baru')
    await publishSession(
      's1',
      snapshot({
        // The same local row twice: the name is resolved once.
        players: [newcomer, newcomer, ...defaultPlayers.slice(1)],
        schedule: [slot(0, ['local-zaki', bowo], [candra, dika])],
      }),
    )

    const schedulePut = writes(fetchMock).find((call) => call.method === 'PUT')
    expect(schedulePut?.body).toEqual({
      games: [{ round: 0, court: 0, sideA: [zaki, bowo], sideB: [candra, dika] }],
    })

    const created = writes(fetchMock).filter(
      (call) => call.method === 'POST' && call.url.endsWith('/players'),
    )
    expect(created).toHaveLength(1)
    expect(created[0].body).toEqual({ name: 'Zaki Baru', gender: 'M' })
    expect(created[0].headers['Idempotency-Key']).toMatch(/\S/)

    const lookups = sequence(fetchMock).filter((call) => call.includes('q=Zaki'))
    expect(lookups).toHaveLength(1)
  })

  it('writes absent players only when the snapshot carries the field', async () => {
    const fetchMock = mockFetch({
      ...rosterRoutes,
      'GET /api/c/plan/sessions/s1': () => ({ body: wire() }),
      'PATCH /api/c/plan/sessions/s1': () => ({ body: { version: 10 } }),
      'PUT /api/c/plan/sessions/s1/schedule': () => ({ body: { version: 11 } }),
      'PATCH /api/c/plan/sessions/s1/absent': () => ({ status: 204 }),
    })

    await publishSession('s1', snapshot({ absentPlayers: [candra] }))

    expect(writes(fetchMock).map((call) => `${call.method} ${call.url}`)).toEqual([
      'PATCH /api/c/plan/sessions/s1',
      'PUT /api/c/plan/sessions/s1/schedule',
      'PATCH /api/c/plan/sessions/s1/absent',
    ])
    const absentWrite = writes(fetchMock).find((call) => call.url.endsWith('/absent'))
    expect(absentWrite?.body).toEqual({ playerIds: [candra] })
    expect(absentWrite?.headers['If-Match']).toBe('"11"')
  })

  it('leaves the absent endpoint alone when the snapshot does not define it', async () => {
    const fetchMock = mockFetch({
      ...rosterRoutes,
      'GET /api/c/plan/sessions/s1': () => ({ body: wire() }),
      'PATCH /api/c/plan/sessions/s1': () => ({ body: { version: 10 } }),
      'PUT /api/c/plan/sessions/s1/schedule': () => ({ body: { version: 11 } }),
    })

    await publishSession('s1', snapshot())

    expect(sequence(fetchMock).some((call) => call.endsWith('/absent'))).toBe(false)
  })

  it('stops at a 412 from the record PATCH without attempting later writes', async () => {
    const fetchMock = mockFetch({
      ...rosterRoutes,
      'GET /api/c/plan/sessions/s1': () => ({ body: wire() }),
      'PATCH /api/c/plan/sessions/s1': () => ({
        status: 412,
        body: { code: 'STALE_VERSION', detail: 'Session was changed by someone else' },
      }),
    })

    const pending = publishSession('s1', snapshot())

    await expect(pending).rejects.toBeInstanceOf(ApiError)
    await expect(pending).rejects.toMatchObject({
      status: 412,
      code: 'STALE_VERSION',
      detail: 'Session was changed by someone else',
    })
    // The read and the record write happened; nothing else was attempted.
    expect(writes(fetchMock).map((call) => `${call.method} ${call.url}`)).toEqual([
      'PATCH /api/c/plan/sessions/s1',
    ])
    expect(sequence(fetchMock)[0]).toBe('GET /api/c/plan/sessions/s1')
  })

  it('skips a multi-game score that carries no sets instead of sending a flat one', async () => {
    const fetchMock = mockFetch({
      ...rosterRoutes,
      'GET /api/c/plan/sessions/s1': () => ({ body: wire([schedulingGame()], { scoring: scoring(3) }) }),
      'PATCH /api/c/plan/sessions/s1': () => ({ body: { version: 10 } }),
      'PUT /api/c/plan/sessions/s1/schedule': () => ({ body: { version: 11 } }),
    })

    await publishSession(
      's1',
      snapshot({
        session: sessionConfig(scoring(3)),
        gameScores: { [toGameKey(0, 0)]: { a: 21, b: 19 } },
      }),
    )

    expect(sequence(fetchMock).filter((call) => call.includes('/games/'))).toEqual([])
  })
})

describe('swapMembers idempotency', () => {
  it('mints a fresh key for each call while keeping If-Match on the given version', async () => {
    const fetchMock = mockFetch({
      'POST /api/c/plan/sessions/s1/swap': () => ({ status: 204 }),
      'GET /api/c/plan/sessions/s1': () => ({ body: wire([schedulingGame()]) }),
    })

    const target = { slot: 0, court: 0, team: 'A' as const, position: 0 as const }
    const other = { slot: 0, court: 0, team: 'A' as const, position: 1 as const }

    await swapMembers('s1', 'player', target, other, 5)
    await swapMembers('s1', 'player', target, other, 5)

    const swaps = writes(fetchMock).filter((call) => call.method === 'POST')
    expect(swaps).toHaveLength(2)
    expect(swaps[0].headers['If-Match']).toBe('"5"')
    expect(swaps[1].headers['If-Match']).toBe('"5"')
    expect(swaps[0].headers['Idempotency-Key']).toMatch(/\S/)
    expect(swaps[1].headers['Idempotency-Key']).toMatch(/\S/)
    expect(swaps[0].headers['Idempotency-Key']).not.toBe(swaps[1].headers['Idempotency-Key'])
  })
})

describe('patchGameScore body', () => {
  const route = () =>
    mockFetch({
      'PATCH /api/c/plan/sessions/s1/games/0-0': () => ({ status: 204 }),
      'GET /api/c/plan/sessions/s1': () => ({ body: wire([schedulingGame()]) }),
    })

  it('sends the set list for a multi-game format', async () => {
    const fetchMock = route()
    const sets = [{ a: 21, b: 19 }, { a: 19, b: 21 }]

    await patchGameScore('s1', '0-0', sets, 7, scoring(3))

    const patch = calls(fetchMock)[0]
    expect(patch.body).toEqual({ sets })
    expect(patch.headers['If-Match']).toBe('"7"')
  })

  it('sends the first set as a flat score for a single-game format', async () => {
    const fetchMock = route()

    await patchGameScore('s1', '0-0', [{ a: 21, b: 19 }], 7, scoring(1))

    expect(calls(fetchMock)[0].body).toEqual({ scoreA: 21, scoreB: 19 })
  })

  it('sends an empty set list when a single-game score is cleared', async () => {
    const fetchMock = route()

    await patchGameScore('s1', '0-0', [], 7, scoring(1))

    expect(calls(fetchMock)[0].body).toEqual({ sets: [] })
  })
})