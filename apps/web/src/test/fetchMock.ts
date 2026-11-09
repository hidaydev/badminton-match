import { vi } from 'vitest'

export type Reply = { status?: number; body?: unknown; headers?: Record<string, string> }
export type Handler = (init: RequestInit | undefined) => Reply

/**
 * Stub `fetch` with a table keyed by `"METHOD /path"`. Unknown requests fail the
 * test instead of silently returning an empty body.
 *
 * A key without a query string is the handler for any query on that path, so a
 * screen that adds a page window (`limit`, `offset`, `status`) does not force
 * every unrelated test to repeat it. A key that names a query still wins when
 * the request matches it, so a test can pin one filter exactly.
 */
export function mockFetch(handlers: Record<string, Handler>) {
  const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input).replace(/^https?:\/\/[^/]+/, '')
    const key = `${init?.method ?? 'GET'} ${url}`
    let handler = handlers[key]
    if (!handler) {
      const bare = url.split('?')[0]
      handler = handlers[`${init?.method ?? 'GET'} ${bare}`]
    }
    if (!handler) throw new Error(`unexpected request: ${key}`)
    const { status = 200, body, headers } = handler(init)
    return {
      ok: status >= 200 && status < 300,
      status,
      headers: new Headers(headers),
      json: async () => body ?? {},
    } as Response
  })
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

export function jsonBody(init: RequestInit | undefined): unknown {
  return typeof init?.body === 'string' ? JSON.parse(init.body) : undefined
}
