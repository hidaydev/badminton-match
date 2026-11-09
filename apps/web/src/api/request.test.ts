import { afterEach, describe, expect, it, vi } from 'vitest'
import { request } from './request'

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe('shared request transport', () => {
  it('retries a 503 with backoff and then resolves', async () => {
    vi.useFakeTimers()
    let calls = 0
    const fetchMock = vi.fn(async () => {
      calls += 1
      if (calls < 3) {
        return new Response(JSON.stringify({ code: 'UNAVAILABLE' }), { status: 503 })
      }
      return new Response(JSON.stringify({ ok: true }), { status: 200 })
    })
    vi.stubGlobal('fetch', fetchMock)

    const promise = request<{ ok: boolean }>('/flaky', {}, { retryBaseDelayMs: 10 })
    await vi.advanceTimersByTimeAsync(100)

    await expect(promise).resolves.toEqual({ ok: true })
    expect(fetchMock).toHaveBeenCalledTimes(3)
  })

  it('aborts a hanging request at the timeout', async () => {
    vi.useFakeTimers()
    vi.stubGlobal(
      'fetch',
      vi.fn((_url: string, init?: RequestInit) => {
        return new Promise((_resolve, reject) => {
          init?.signal?.addEventListener('abort', () => {
            reject(new DOMException('Aborted', 'AbortError'))
          })
        })
      }),
    )

    const promise = request('/slow', {}, { timeoutMs: 25 })
    const failure = expect(promise).rejects.toMatchObject({ name: 'AbortError' })
    await vi.advanceTimersByTimeAsync(25)

    await failure
  })
})
