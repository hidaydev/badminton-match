import { act, renderHook, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { Player, PlayerClaim } from '../api'
import { useMyPlayer, usePlayerDetail, usePlayers } from '../hooks'

type Reply = { status?: number; body?: unknown }

function makePlayer(id: string, name = id): Player {
  return {
    id,
    name,
    gender: 'F',
    tier: 'C',
    userId: null,
    createdAt: '2026-11-01 10:00:00+07',
    updatedAt: '2026-11-01 10:00:00+07',
    aliases: [],
  }
}

function makePlayers(count: number, prefix = 'p'): Player[] {
  return Array.from({ length: count }, (_, index) => makePlayer(`${prefix}${index + 1}`))
}

function makeClaim(id: string): PlayerClaim {
  return {
    id,
    userId: 'u9',
    status: 'pending',
    decidedBy: '',
    decidedAt: '',
    reason: '',
    createdAt: '2026-11-02 09:00:00+07',
  }
}

/**
 * A fetch stub that holds every request open until the test answers it, so the
 * in-flight state can be asserted before the answer lands.
 */
function stubFetch() {
  const calls: Array<{ url: string; init: RequestInit | undefined }> = []
  const open: Array<(reply: Reply) => void> = []

  vi.stubGlobal(
    'fetch',
    vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
      calls.push({ url: String(input), init })
      return new Promise<Response>((resolve) => {
        open.push((reply) => {
          const status = reply.status ?? 200
          resolve({
            ok: status >= 200 && status < 300,
            status,
            headers: new Headers(),
            json: async () => reply.body ?? {},
          } as Response)
        })
      })
    }),
  )

  return {
    calls,
    async deliver(index: number, reply: Reply) {
      await act(async () => {
        open[index](reply)
        await drain()
      })
    },
  }
}

/** Let the fetch promise chain reach its last `.then` without a timer. */
async function drain(): Promise<void> {
  for (let turn = 0; turn < 8; turn += 1) await Promise.resolve()
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('usePlayers', () => {
  it('appends the next page to the list it keeps while the page loads, then stops asking after a short page', async () => {
    const server = stubFetch()
    const { result } = renderHook(() => usePlayers('acme', ''))

    expect(server.calls[0].url).toBe('/api/c/acme/players?limit=50')
    await server.deliver(0, { body: { items: makePlayers(50) } })

    await waitFor(() => expect(result.current.items).toHaveLength(50))
    expect(result.current.hasMore).toBe(true)

    act(() => result.current.loadMore())

    expect(server.calls[1].url).toBe('/api/c/acme/players?cursor=p50&limit=50')
    expect(result.current.loadingMore).toBe(true)
    expect(result.current.items).toHaveLength(50)
    expect(result.current.items?.map((row) => row.id)).toContain('p1')

    await server.deliver(1, { body: { items: makePlayers(2, 'tail') } })

    await waitFor(() => expect(result.current.items).toHaveLength(52))
    expect(result.current.loadingMore).toBe(false)
    expect(result.current.hasMore).toBe(false)
    expect(result.current.items?.map((row) => row.id).slice(50)).toEqual(['tail1', 'tail2'])

    act(() => result.current.loadMore())

    expect(server.calls).toHaveLength(2)
    expect(result.current.items).toHaveLength(52)
  })

  it('replaces the accumulated list when the search term changes', async () => {
    const server = stubFetch()
    const { result, rerender } = renderHook(({ query }) => usePlayers('acme', query), {
      initialProps: { query: '' },
    })

    await server.deliver(0, { body: { items: makePlayers(50) } })
    await waitFor(() => expect(result.current.items).toHaveLength(50))

    rerender({ query: 'an' })

    expect(server.calls[1].url).toBe('/api/c/acme/players?q=an&limit=50')
    expect(result.current.items).toBeNull()
    expect(result.current.loading).toBe(true)

    await server.deliver(1, { body: { items: [makePlayer('an1')] } })

    await waitFor(() => expect(result.current.items).toHaveLength(1))
    expect(result.current.items?.map((row) => row.id)).toEqual(['an1'])
    expect(result.current.hasMore).toBe(false)
  })

  it('drops an answer that arrives for the previous search term', async () => {
    const server = stubFetch()
    const { result, rerender } = renderHook(({ query }) => usePlayers('acme', query), {
      initialProps: { query: 'an' },
    })

    rerender({ query: 'bo' })
    expect(server.calls).toHaveLength(2)

    await server.deliver(0, { body: { items: makePlayers(3, 'an') } })
    expect(result.current.items).toBeNull()

    await server.deliver(1, { body: { items: [makePlayer('bo1')] } })
    await waitFor(() => expect(result.current.items).toHaveLength(1))
    expect(result.current.items?.map((row) => row.id)).toEqual(['bo1'])
  })

  it('reports a 404 on the list read as notFound', async () => {
    const server = stubFetch()
    const { result } = renderHook(() => usePlayers('acme', ''))

    await server.deliver(0, { status: 404, body: { code: 'NOT_FOUND' } })

    await waitFor(() => expect(result.current.error).toBe('notFound'))
    expect(result.current.loading).toBe(false)
    expect(result.current.items).toBeNull()
  })

  it('reports a 500 on the list read as failed', async () => {
    const server = stubFetch()
    const { result } = renderHook(() => usePlayers('acme', ''))

    await server.deliver(0, { status: 500, body: {} })

    await waitFor(() => expect(result.current.error).toBe('failed'))
    expect(result.current.loading).toBe(false)
  })

  it('keeps the loaded page and marks failed when a follow-up page request fails', async () => {
    const server = stubFetch()
    const { result } = renderHook(() => usePlayers('acme', ''))

    await server.deliver(0, { body: { items: makePlayers(50) } })
    await waitFor(() => expect(result.current.items).toHaveLength(50))

    act(() => result.current.loadMore())
    await server.deliver(1, { status: 500, body: {} })

    await waitFor(() => expect(result.current.error).toBe('failed'))
    expect(result.current.items).toHaveLength(50)
    expect(result.current.loadingMore).toBe(false)
  })

  it('makes no request while the slug is null', () => {
    const server = stubFetch()
    const { result } = renderHook(() => usePlayers(null, ''))

    expect(server.calls).toHaveLength(0)
    expect(result.current.items).toBeNull()
    expect(result.current.loading).toBe(false)
  })
})

describe('useMyPlayer', () => {
  it('returns the player the account owns once the read resolves', async () => {
    const server = stubFetch()
    const { result } = renderHook(() => useMyPlayer('acme'))

    expect(server.calls[0].url).toBe('/api/c/acme/players?mine=1')
    expect(result.current).toBeNull()

    await server.deliver(0, { body: { items: [makePlayer('p1', 'Ani')] } })

    await waitFor(() => expect(result.current?.name).toBe('Ani'))
  })

  it('returns null on a 404 and does not throw', async () => {
    const server = stubFetch()
    const { result } = renderHook(() => useMyPlayer('acme'))

    await server.deliver(0, { status: 404, body: { code: 'NOT_FOUND' } })

    await waitFor(() => expect(server.calls).toHaveLength(1))
    expect(result.current).toBeNull()
  })

  it('returns null when the read fails with a 500', async () => {
    const server = stubFetch()
    const { result } = renderHook(() => useMyPlayer('acme'))

    await server.deliver(0, { status: 500, body: {} })

    await waitFor(() => expect(server.calls).toHaveLength(1))
    expect(result.current).toBeNull()
  })

  it('makes no request while the slug is null', () => {
    const server = stubFetch()
    const { result } = renderHook(() => useMyPlayer(null))

    expect(server.calls).toHaveLength(0)
    expect(result.current).toBeNull()
  })
})

describe('usePlayerDetail', () => {
  it('loads the player and their claims and reports neither while the read is open', async () => {
    const server = stubFetch()
    const { result } = renderHook(() => usePlayerDetail('acme', 'p1'))

    expect(server.calls.map((call) => call.url)).toEqual([
      '/api/c/acme/players/p1',
      '/api/c/acme/players/p1/claims?limit=500&offset=0',
    ])
    expect(result.current.loading).toBe(true)
    expect(result.current.player).toBeNull()
    expect(result.current.claims).toBeNull()

    await server.deliver(0, { body: makePlayer('p1', 'Ani') })
    await server.deliver(1, { body: { items: [makeClaim('c1'), makeClaim('c2')] } })

    await waitFor(() => expect(result.current.player?.name).toBe('Ani'))
    expect(result.current.claims?.map((row) => row.id)).toEqual(['c1', 'c2'])
    expect(result.current.loading).toBe(false)
    expect(result.current.error).toBeNull()
  })

  it('ignores a player answer that arrives after the requested id changed', async () => {
    const server = stubFetch()
    const { result, rerender } = renderHook(
      ({ id }) => usePlayerDetail('acme', id),
      { initialProps: { id: 'p1' } },
    )

    rerender({ id: 'p2' })
    expect(server.calls).toHaveLength(4)

    await server.deliver(0, { body: makePlayer('p1', 'Ani') })

    expect(result.current.player).toBeNull()
    expect(result.current.loading).toBe(true)

    await server.deliver(2, { body: makePlayer('p2', 'Budi') })
    await server.deliver(3, { body: { items: [] } })

    await waitFor(() => expect(result.current.player?.name).toBe('Budi'))
    expect(result.current.claims).toEqual([])
  })
})