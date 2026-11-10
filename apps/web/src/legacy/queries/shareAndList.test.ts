import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mockFetch } from '../../test/fetchMock'
import {
  deleteSessionShareLink,
  ensureSessionShareLink,
  getSessionShareCode,
  listSessions,
  setCommunitySlug,
  setSessionLock,
} from './endpoints'
import { ApiError } from './retry'

const row = {
  id: 's1',
  title: 'Tuesday',
  date: '2026-11-03',
  status: 'draft',
  version: 4,
}

const calls = (fetchMock: ReturnType<typeof mockFetch>) =>
  fetchMock.mock.calls.map(([input, init]) => ({
    method: init?.method ?? 'GET',
    url: String(input),
    headers: (init?.headers ?? {}) as unknown as Record<string, string>,
    body: init?.body,
  }))

beforeEach(() => {
  window.history.replaceState({}, '', '/c/plan')
  setCommunitySlug('plan')
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe('listSessions', () => {
  it('leaves out offset=0 and a blank query, but trims a real one', async () => {
    const fetchMock = mockFetch({
      'GET /api/c/plan/sessions?limit=20': () => ({ body: { items: [row], total: 1 } }),
      'GET /api/c/plan/sessions?limit=20&q=cup': () => ({ body: { items: [], total: 0 } }),
    })

    await listSessions({ limit: 20, offset: 0, q: '   ' })
    await listSessions({ limit: 20, offset: 0, q: '  cup  ' })

    expect(String(fetchMock.mock.calls[0][0])).toContain('/sessions?limit=20')
    expect(String(fetchMock.mock.calls[0][0])).not.toContain('offset=')
    expect(String(fetchMock.mock.calls[0][0])).not.toContain('q=')
    expect(String(fetchMock.mock.calls[1][0])).toContain('q=cup')
  })

  it('turns a nextCursor no further than the requested offset into null', async () => {
    mockFetch({
      'GET /api/c/plan/sessions?offset=20': () => ({ body: { items: [row], nextCursor: '20' } }),
      'GET /api/c/plan/sessions?offset=40': () => ({ body: { items: [row], nextCursor: '60' } }),
    })

    // A cursor equal to the offset would page the same rows forever.
    await expect(listSessions({ offset: 20 })).resolves.toMatchObject({ nextOffset: null })
    await expect(listSessions({ offset: 40 })).resolves.toMatchObject({ nextOffset: 60 })
  })

  it('refuses a response whose items are not an array instead of showing an empty list', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
    mockFetch({
      'GET /api/c/plan/sessions': () => ({ body: { items: { s1: row } } }),
    })

    await expect(listSessions()).rejects.toBeInstanceOf(ApiError)
    await expect(listSessions()).rejects.toThrow('Invalid session list received from server')
    expect(warn).toHaveBeenCalled()
  })

  it('maps a row to the legacy meta shape', async () => {
    mockFetch({
      'GET /api/c/plan/sessions': () => ({
        body: { items: [{ ...row, status: 'locked', playerCount: 8, totalGames: 12 }] },
      }),
    })

    const page = await listSessions()

    expect(page.items).toEqual([
      {
        id: 's1',
        title: 'Tuesday',
        date: '2026-11-03',
        playerCount: 8,
        totalGames: 12,
        locked: true,
        status: 'locked',
      },
    ])
    // No cursor means no next page, and the total falls back to what arrived.
    expect(page.nextOffset).toBeNull()
    expect(page.total).toBe(1)
  })
})

describe('session share link', () => {
  it('reads a missing link as null but rethrows a server failure', async () => {
    vi.useFakeTimers()
    let failures = 0
    const fetchMock = mockFetch({
      'GET /api/c/plan/sessions/s1/share': () => ({ status: 404 }),
      'GET /api/c/plan/sessions/s2/share': () => {
        failures += 1
        return { status: 500, body: { detail: 'share store is down' } }
      },
    })

    await expect(getSessionShareCode('s1')).resolves.toBeNull()

    const pending = getSessionShareCode('s2')
    const verdict = expect(pending).rejects.toMatchObject({
      status: 500,
      message: 'share store is down',
    })
    // A 500 on a read is retried by the transport, so drive the backoff.
    await vi.advanceTimersByTimeAsync(7_000)
    await verdict
    expect(failures).toBe(4)
    expect(calls(fetchMock).some((call) => call.url.includes('/share'))).toBe(true)
  })

  it('keeps a live code without issuing a second one', async () => {
    const fetchMock = mockFetch({
      'GET /api/c/plan/sessions/s1/share': () => ({ body: { code: 'LIVE1' } }),
    })

    await expect(ensureSessionShareLink('s1')).resolves.toBe('LIVE1')

    expect(calls(fetchMock).map((call) => call.method)).toEqual(['GET'])
  })

  it('creates a code when none is live', async () => {
    const fetchMock = mockFetch({
      'GET /api/c/plan/sessions/s1/share': () => ({ status: 404 }),
      'POST /api/c/plan/sessions/s1/share': () => ({ body: { code: 'NEW1' } }),
    })

    await expect(ensureSessionShareLink('s1')).resolves.toBe('NEW1')

    const sequence = calls(fetchMock)
    expect(sequence.map((call) => call.method)).toEqual(['GET', 'POST'])
    expect(sequence[1].url).toContain('/api/c/plan/sessions/s1/share')
    expect(sequence[1].headers['Idempotency-Key']).toMatch(/\S/)
  })

  it('deletes the link and resolves undefined on 204', async () => {
    const fetchMock = mockFetch({
      'DELETE /api/c/plan/sessions/s1/share': () => ({ status: 204 }),
    })

    await expect(deleteSessionShareLink('s1')).resolves.toBeUndefined()

    const [only] = calls(fetchMock)
    expect(only.method).toBe('DELETE')
    expect(only.url).toContain('/api/c/plan/sessions/s1/share')
    expect(only.body).toBeUndefined()
  })
})

describe('setSessionLock', () => {
  it('posts to lock or unlock with the expected version', async () => {
    const fetchMock = mockFetch({
      'POST /api/c/plan/sessions/s1/lock': () => ({ status: 204 }),
      'POST /api/c/plan/sessions/s1/unlock': () => ({ status: 204 }),
    })

    await expect(setSessionLock('s1', true, 7)).resolves.toBeUndefined()
    await expect(setSessionLock('s1', false, 8)).resolves.toBeUndefined()

    const [lock, unlock] = calls(fetchMock)
    expect(lock.method).toBe('POST')
    expect(lock.url).toContain('/api/c/plan/sessions/s1/lock')
    expect(lock.headers['If-Match']).toBe('"7"')
    expect(lock.body).toBeUndefined()
    expect(unlock.url).toContain('/api/c/plan/sessions/s1/unlock')
    expect(unlock.headers['If-Match']).toBe('"8"')
  })
})