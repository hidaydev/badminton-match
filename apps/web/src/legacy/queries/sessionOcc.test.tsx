import type { ReactNode } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mockFetch } from '../../test/fetchMock'
import { setCommunitySlug } from './endpoints'
import { useSetScore } from './sessions'
import type { CloudSnapshot } from './types'

const sessionPath = 'GET /api/c/plan/sessions/s1'
const gamePath = 'PATCH /api/c/plan/sessions/s1/games/0-0'

const detail = (version: number) => ({
  id: 's1',
  title: 'Sunday',
  date: '2026-11-21',
  startTime: '09:00',
  slotMinutes: 30,
  status: 'draft',
  version,
  participants: [{ playerId: 'p1', name: 'Arya', absent: false }],
  games: [{ round: 0, court: 0, sideA: ['p1', ''], sideB: ['', ''], scoreA: null, scoreB: null, status: 'scheduled' }],
  scoring: { preset: 'first21', label: 'First to 21', gamesToWin: 1, pointsToWin: 21, winBy: 2, maxPoints: 30, deuceAt: 20, changeEndsAt: null },
})

const seed = { version: 7, session: { scoring: detail(7).scoring } } as unknown as CloudSnapshot

function Providers({ client, children }: { client: QueryClient; children: ReactNode }) {
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>
}

describe('session OCC recovery read', () => {
  beforeEach(() => {
    setCommunitySlug('plan')
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  // The recovery read after a version conflict must reach the server. Under the
  // app's 30s `staleTime` it would answer from the cache and the retry would
  // resend the same stale If-Match, so a lost write never recovers (REL-FE-01).
  it('issues a network read after a version conflict instead of reusing the cached version', async () => {
    let sessionGets = 0
    const patches: string[] = []
    mockFetch({
      [gamePath]: (init) => {
        patches.push((init?.headers as Record<string, string>)['If-Match'])
        // The first write loses the conflict; the second must carry the version
        // that the recovery read just learned.
        return patches.length === 1
          ? { status: 412, body: { code: 'STALE_VERSION', detail: 'version mismatch' } }
          : { body: { version: 8 } }
      },
      [sessionPath]: () => {
        sessionGets += 1
        return { body: detail(8) }
      },
    })

    const client = new QueryClient({
      defaultOptions: { queries: { retry: false, staleTime: 30_000 }, mutations: { retry: false } },
    })
    client.setQueryData(['plan', 'session', 's1'], seed)

    const { result } = renderHook(() => useSetScore('s1'), {
      wrapper: ({ children }) => <Providers client={client}>{children}</Providers>,
    })

    await act(async () => {
      await result.current.mutateAsync({ key: '0-0', sets: [{ a: 21, b: 18 }] })
    })

    // One recovery read, then the read-back the endpoint performs after a write.
    expect(sessionGets).toBe(2)
    expect(patches).toEqual(['"7"', '"8"'])
  })

  // The other half of the same proof, on the cache directly: without the
  // per-call override the identical read is answered from cache — this is the
  // shape the fix removed, and why `sessionGets` above would have stayed at 1
  // while the retry resent If-Match "7".
  it('answers the same read from the cache when no per-call staleTime is given', async () => {
    let sessionGets = 0
    mockFetch({
      [sessionPath]: () => {
        sessionGets += 1
        return { body: detail(8) }
      },
    })

    const client = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: 30_000 } } })
    client.setQueryData(['plan', 'session', 's1'], seed)

    const cached = await client.fetchQuery<CloudSnapshot>({
      queryKey: ['plan', 'session', 's1'],
      queryFn: () => Promise.reject(new Error('no request expected')),
    })
    expect(sessionGets).toBe(0)
    expect(cached).toBe(seed)
  })
})
