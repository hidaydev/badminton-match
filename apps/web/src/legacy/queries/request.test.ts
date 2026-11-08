import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mockFetch } from '../../test/fetchMock'
import {
  BASE_URL,
  communityApiPath,
  issueSessionTicket,
  request,
  setCommunitySlug,
} from './endpoints'
import { ApiError } from './retry'

const CLIENT_OUTDATED = 'majadu:client-outdated'
const SESSION_EXPIRED = 'majadu:session-expired'

beforeEach(() => {
  window.history.replaceState({}, '', '/')
  setCommunitySlug('majadu')
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe('request transport', () => {
  it('sends the API version and cookie credentials on every request', async () => {
    const fetchMock = mockFetch({ 'GET /api/sessions': () => ({ body: { items: [] } }) })

    await request('GET', '/sessions')

    const [input, init] = fetchMock.mock.calls[0]
    expect(String(input)).toBe(`${BASE_URL}/sessions`)
    expect(init?.credentials).toBe('include')
    expect(init?.headers).toMatchObject({ 'X-API-Version': '2' })
    expect(init?.headers).not.toHaveProperty('Content-Type')
    expect(init?.body).toBeUndefined()
  })

  it('adds the JSON content type and a serialised body only when a body is given', async () => {
    const fetchMock = mockFetch({ 'POST /api/sessions': () => ({ body: { id: 's1' } }) })

    await request('POST', '/sessions', { title: 'Sunday' })

    const init = fetchMock.mock.calls[0][1]
    expect(init?.headers).toMatchObject({
      'X-API-Version': '2',
      'Content-Type': 'application/json',
    })
    expect(init?.body).toBe(JSON.stringify({ title: 'Sunday' }))
  })

  it('resolves a 204 to undefined instead of reading a body', async () => {
    const fetchMock = mockFetch({ 'DELETE /api/sessions/s1/share': () => ({ status: 204 }) })

    await expect(request('DELETE', '/sessions/s1/share')).resolves.toBeUndefined()

    // The header-aware form keeps the headers and still has no body.
    const withHeaders = await request('DELETE', '/sessions/s1/share', undefined, undefined, undefined, true)
    expect(withHeaders).toMatchObject({ data: undefined })
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('surfaces the code and detail of an error body', async () => {
    mockFetch({
      'PATCH /api/sessions/s1': () => ({
        status: 412,
        body: { code: 'STALE_VERSION', detail: 'Session was changed by someone else' },
      }),
    })

    const failure = request('PATCH', '/sessions/s1', { title: 'Sunday' })

    await expect(failure).rejects.toBeInstanceOf(ApiError)
    await expect(failure).rejects.toMatchObject({
      status: 412,
      code: 'STALE_VERSION',
      detail: 'Session was changed by someone else',
      message: 'Session was changed by someone else',
    })
  })

  it('keeps the HTTP status line when the error body is not JSON', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => ({
        ok: false,
        status: 400,
        statusText: 'Bad Request',
        headers: new Headers(),
        json: async () => {
          throw new Error('not json')
        },
      }) as unknown as Response),
    )

    await expect(request('POST', '/sessions', { title: '' })).rejects.toMatchObject({
      status: 400,
      message: '400 Bad Request',
      code: null,
      detail: null,
    })
  })

  it('reports a 401 as an expired session', async () => {
    const expired = vi.fn()
    window.addEventListener(SESSION_EXPIRED, expired)
    mockFetch({ 'GET /api/me': () => ({ status: 401 }) })

    await expect(request('GET', '/me')).rejects.toMatchObject({ status: 401 })

    expect(expired).toHaveBeenCalledTimes(1)
    window.removeEventListener(SESSION_EXPIRED, expired)
  })

  it('reports a 410 CLIENT_OUTDATED as a reload, and an ordinary 410 is not one', async () => {
    const outdated = vi.fn()
    const expired = vi.fn()
    window.addEventListener(CLIENT_OUTDATED, outdated)
    window.addEventListener(SESSION_EXPIRED, expired)

    mockFetch({
      'GET /api/outdated': () => ({
        status: 410,
        body: { code: 'CLIENT_OUTDATED', detail: 'Reload before trying again' },
      }),
      'GET /api/gone': () => ({ status: 410, body: { detail: 'Session is gone' } }),
    })

    await expect(request('GET', '/outdated')).rejects.toMatchObject({ code: 'CLIENT_OUTDATED' })
    await expect(request('GET', '/gone')).rejects.toMatchObject({ status: 410, code: null })

    expect(outdated).toHaveBeenCalledTimes(1)
    expect(expired).not.toHaveBeenCalled()
    window.removeEventListener(CLIENT_OUTDATED, outdated)
    window.removeEventListener(SESSION_EXPIRED, expired)
  })

  it('retries a read after the Retry-After window, and only that long', async () => {
    vi.useFakeTimers()
    let attempts = 0
    mockFetch({
      'GET /api/slow': () => {
        attempts += 1
        return attempts === 1
          ? { status: 503, headers: { 'Retry-After': '2' } }
          : { body: { ok: true } }
      },
    })

    const pending = request('GET', '/slow')
    await vi.advanceTimersByTimeAsync(0)
    expect(attempts).toBe(1)

    // The backoff alone would have been 1s; the header asks for 2s.
    await vi.advanceTimersByTimeAsync(1_999)
    expect(attempts).toBe(1)

    await vi.advanceTimersByTimeAsync(1)
    expect(attempts).toBe(2)
    await expect(pending).resolves.toEqual({ ok: true })
  })

  it('does not replay a mutation that failed with 503', async () => {
    let attempts = 0
    mockFetch({
      'POST /api/sessions': () => {
        attempts += 1
        return { status: 503 }
      },
    })

    await expect(request('POST', '/sessions', { title: 'Sunday' })).rejects.toMatchObject({
      status: 503,
    })
    expect(attempts).toBe(1)
  })

  it('stops on an aborted caller signal without a second attempt', async () => {
    const controller = new AbortController()
    let attempts = 0
    vi.stubGlobal(
      'fetch',
      vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
        attempts += 1
        return new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener('abort', () =>
            reject(new DOMException('The operation was aborted.', 'AbortError')),
          )
        })
      }),
    )

    const pending = request('GET', '/slow', undefined, controller.signal)
    controller.abort()

    await expect(pending).rejects.toMatchObject({ name: 'AbortError' })
    expect(attempts).toBe(1)
  })

  it('gives up on its own timeout instead of retrying', async () => {
    vi.useFakeTimers()
    let attempts = 0
    vi.stubGlobal(
      'fetch',
      vi.fn((_input: RequestInfo | URL, init?: RequestInit) => {
        attempts += 1
        return new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener('abort', () =>
            reject(new DOMException('The operation timed out.', 'AbortError')),
          )
        })
      }),
    )

    const pending = request('GET', '/slow')
    const verdict = expect(pending).rejects.toMatchObject({ name: 'AbortError' })
    await vi.advanceTimersByTimeAsync(30_000)
    await verdict

    expect(attempts).toBe(1)
  })
})

describe('community paths', () => {
  it('refuses to build a path before a slug is known, without any fetch', async () => {
    setCommunitySlug('')
    const fetchMock = mockFetch({})

    expect(() => communityApiPath('/sessions')).toThrow(ApiError)
    expect(() => communityApiPath('/sessions')).toThrow('community slug is not set')
    await expect(issueSessionTicket('s1')).rejects.toThrow('community slug is not set')

    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('prefixes the slug once it is known', () => {
    setCommunitySlug('majadu')

    expect(communityApiPath('/sessions')).toBe('/c/majadu/sessions')
  })
})