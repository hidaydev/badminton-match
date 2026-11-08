import type { ReactNode } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mockFetch } from '../../test/fetchMock'
import type { CloudSnapshot } from '../types'
import { setCommunitySlug } from './endpoints'
import { useSessionRealtime } from './sessions'

/**
 * The smallest WebSocket the hook can drive: it records what the hook sent and
 * lets the test play the server side. Installed on `globalThis` per test.
 */
class FakeSocket {
  static CONNECTING = 0
  static OPEN = 1
  static CLOSING = 2
  static CLOSED = 3
  static instances: FakeSocket[] = []

  static get last(): FakeSocket {
    const socket = FakeSocket.instances[FakeSocket.instances.length - 1]
    if (!socket) throw new Error('no socket was opened')
    return socket
  }

  readonly url: string
  readyState = FakeSocket.CONNECTING
  closed = false
  sent: string[] = []
  onopen: (() => void) | null = null
  onclose: (() => void) | null = null
  onerror: (() => void) | null = null
  onmessage: ((event: { data: string }) => void) | null = null

  constructor(url: string) {
    this.url = url
    FakeSocket.instances.push(this)
  }

  send(data: string) {
    this.sent.push(data)
  }

  close() {
    this.closed = true
    this.readyState = FakeSocket.CLOSED
    this.onclose?.()
  }

  /** Server accepts the upgrade. */
  open() {
    this.readyState = FakeSocket.OPEN
    this.onopen?.()
  }

  /** Connection drops without a frame from the server. */
  drop() {
    this.readyState = FakeSocket.CLOSED
    this.onclose?.()
  }

  receive(frame: unknown) {
    this.onmessage?.({ data: JSON.stringify(frame) })
  }

  frames(): unknown[] {
    return this.sent.map((raw) => JSON.parse(raw) as unknown)
  }
}

const sessionKey = ['majadu', 'session', 's1']

function ticketMock() {
  let issued = 0
  const fetchMock = mockFetch({
    'POST /api/c/majadu/sessions/s1/ws-ticket': () => {
      issued += 1
      return { body: { ticket: `tic-${issued}`, expiresIn: 60 } }
    },
  })
  return { fetchMock, issued: () => issued }
}

function newClient(version?: number) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: Infinity } },
  })
  if (version !== undefined) {
    client.setQueryData(sessionKey, {
      version,
      session: {},
      players: [],
      fixMatches: [],
      schedule: [],
      playedGames: [],
      gameScores: {},
    } as unknown as CloudSnapshot)
  }
  return client
}

function renderRealtime(client: QueryClient, enabled = true) {
  return renderHook(() => useSessionRealtime('s1', enabled), {
    wrapper: ({ children }: { children: ReactNode }) => (
      <QueryClientProvider client={client}>{children}</QueryClientProvider>
    ),
  })
}

/** Let the ticket promise from `connect` settle inside act. */
async function flush() {
  await act(async () => {})
}

beforeEach(() => {
  window.history.replaceState({}, '', '/c/majadu')
  setCommunitySlug('majadu')
  FakeSocket.instances = []
  vi.stubGlobal('WebSocket', FakeSocket)
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe('useSessionRealtime connection', () => {
  it('issues a ticket before opening the socket and passes it in the query', async () => {
    const order: string[] = []
    const fetchMock = mockFetch({
      'POST /api/c/majadu/sessions/s1/ws-ticket': () => {
        order.push('ticket')
        return { body: { ticket: 'tic-1', expiresIn: 60 } }
      },
    })
    const Original = FakeSocket
    // Record construction order without losing the class the hook calls.
    class RecordingSocket extends Original {
      constructor(url: string) {
        super(url)
        order.push('socket')
      }
    }
    vi.stubGlobal('WebSocket', RecordingSocket)

    renderRealtime(newClient())
    await flush()

    expect(order).toEqual(['ticket', 'socket'])
    expect(fetchMock.mock.calls[0][1]?.method).toBe('POST')
    expect(String(fetchMock.mock.calls[0][0])).toContain(
      '/api/c/majadu/sessions/s1/ws-ticket',
    )
    expect(FakeSocket.last.url).toContain('/ws/c/majadu/sessions/s1?ticket=tic-1')
  })

  it('subscribes from sequence zero as soon as the socket opens', async () => {
    ticketMock()
    renderRealtime(newClient())
    await flush()

    FakeSocket.last.open()

    expect(FakeSocket.last.frames()).toEqual([{ type: 'subscribe', lastSeq: 0 }])
  })

  it('never asks for a ticket when the hook is disabled', async () => {
    const { fetchMock, issued } = ticketMock()

    renderRealtime(newClient(), false)
    await flush()

    expect(fetchMock).not.toHaveBeenCalled()
    expect(issued()).toBe(0)
    expect(FakeSocket.instances).toHaveLength(0)
  })
})

describe('useSessionRealtime frames', () => {
  it('ignores a session.changed frame that is not newer than the cached version', async () => {
    ticketMock()
    const client = newClient(5)
    const invalidate = vi.spyOn(client, 'invalidateQueries').mockResolvedValue()
    renderRealtime(client)
    await flush()
    FakeSocket.last.open()

    FakeSocket.last.receive({ type: 'session.changed', seq: 5 })
    FakeSocket.last.receive({ type: 'session.changed', seq: 4 })

    // Our own write already brought version 5 into the cache; refetching on the
    // echo would double every save's traffic.
    expect(invalidate).not.toHaveBeenCalled()
  })

  it('invalidates exactly the session key for a newer sequence', async () => {
    ticketMock()
    const client = newClient(5)
    const invalidate = vi.spyOn(client, 'invalidateQueries').mockResolvedValue()
    renderRealtime(client)
    await flush()
    FakeSocket.last.open()

    await act(async () => {
      FakeSocket.last.receive({ type: 'session.changed', seq: 6 })
    })

    expect(invalidate).toHaveBeenCalledTimes(1)
    expect(invalidate.mock.calls[0][0]).toEqual({ queryKey: sessionKey })
  })

  it('invalidates once on the first open after a reconnect, not on the first open', async () => {
    vi.useFakeTimers()
    const { issued } = ticketMock()
    const client = newClient(5)
    const invalidate = vi.spyOn(client, 'invalidateQueries').mockResolvedValue()
    renderRealtime(client)
    await flush()

    FakeSocket.last.open()
    expect(invalidate).not.toHaveBeenCalled()

    FakeSocket.last.drop()
    await vi.advanceTimersByTimeAsync(1_000)
    await flush()
    expect(issued()).toBe(2)
    expect(FakeSocket.instances).toHaveLength(2)

    FakeSocket.last.open()
    expect(invalidate).toHaveBeenCalledTimes(1)
    expect(invalidate.mock.calls[0][0]).toEqual({ queryKey: sessionKey })
  })

  it('closes and stops reconnecting when the link is revoked', async () => {
    vi.useFakeTimers()
    const { issued } = ticketMock()
    renderRealtime(newClient(5))
    await flush()
    const socket = FakeSocket.last
    socket.open()

    socket.receive({ type: 'revoked' })

    expect(socket.closed).toBe(true)
    await vi.advanceTimersByTimeAsync(120_000)
    expect(FakeSocket.instances).toHaveLength(1)
    expect(issued()).toBe(1)
  })
})

describe('useSessionRealtime reconnect schedule', () => {
  it('doubles the delay on every close and caps it at thirty seconds', async () => {
    vi.useFakeTimers()
    const { issued } = ticketMock()
    renderRealtime(newClient())
    await flush()
    expect(FakeSocket.instances).toHaveLength(1)

    // attempt: 0 -> 1s, then 2s, 4s, 8s, 16s, 30s, 30s.
    for (const delay of [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000]) {
      const before = FakeSocket.instances.length
      FakeSocket.last.drop()

      await vi.advanceTimersByTimeAsync(delay - 1)
      expect(FakeSocket.instances).toHaveLength(before)

      await vi.advanceTimersByTimeAsync(1)
      await flush()
      expect(FakeSocket.instances).toHaveLength(before + 1)
    }

    expect(issued()).toBe(8)
  })

  it('clears the reconnect timer and closes the socket on unmount', async () => {
    vi.useFakeTimers()
    const { issued } = ticketMock()
    const first = renderRealtime(newClient())
    await flush()
    const open = FakeSocket.last
    open.open()

    first.unmount()
    expect(open.closed).toBe(true)

    // A fresh mount whose socket drops, then unmounts before the retry fires.
    const second = renderRealtime(newClient())
    await flush()
    expect(FakeSocket.instances).toHaveLength(2)
    FakeSocket.last.drop()
    second.unmount()

    await vi.advanceTimersByTimeAsync(60_000)
    expect(FakeSocket.instances).toHaveLength(2)
    expect(issued()).toBe(2)
  })
})