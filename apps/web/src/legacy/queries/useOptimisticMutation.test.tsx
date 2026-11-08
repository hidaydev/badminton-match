import type { ReactNode } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { act, renderHook, waitFor } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../api/errors'
import type { CloudSnapshot } from '../types'
import { useOptimisticMutation } from './useOptimisticMutation'

const snapshot = {
  version: 1,
  session: {},
  players: [],
  fixMatches: [],
  schedule: [],
  playedGames: [],
  gameScores: {},
} as unknown as CloudSnapshot

function Providers({ client, children }: { client: QueryClient; children: ReactNode }) {
  return <QueryClientProvider client={client}>{children}</QueryClientProvider>
}

const key = ['session', 's1']

type Vars = { played: string }

function harness(options: {
  initial?: CloudSnapshot
  publish: (id: string, snap: CloudSnapshot) => Promise<CloudSnapshot>
  fetchSnapshot?: (id: string) => Promise<CloudSnapshot | null>
  optimisticUpdate?: (old: CloudSnapshot | null, vars: Vars) => CloudSnapshot | null
  applyOptimistic?: boolean
  refetchOnAnyError?: boolean
  onSuccessCallback?: () => Promise<void>
}) {
  const client = new QueryClient({
    defaultOptions: {
      mutations: { retry: false },
      queries: { retry: false, gcTime: Infinity },
    },
  })
  if (options.initial) client.setQueryData(key, options.initial)
  const fetchSnapshot = vi.fn(options.fetchSnapshot ?? (async () => null))
  const publish = vi.fn(options.publish)

  const view = renderHook(
    () =>
      useOptimisticMutation<CloudSnapshot, Vars>('s1', {
        queryKey: key,
        fetchSnapshot,
        publish,
        optimisticUpdate: options.optimisticUpdate ?? ((old) => old),
        applyOptimistic: options.applyOptimistic,
        refetchOnAnyError: options.refetchOnAnyError,
        onSuccessCallback: options.onSuccessCallback,
      }),
    { wrapper: ({ children }) => <Providers client={client}>{children}</Providers> },
  )

  return { client, fetchSnapshot, publish, result: view.result }
}

/** The optimistic value differs from the starting one on purpose. */
const poke = (old: CloudSnapshot | null, vars: Vars): CloudSnapshot => ({
  ...(old ?? snapshot),
  playedGames: [...(old?.playedGames ?? []), vars.played],
})

describe('useOptimisticMutation retry', () => {
  it('ends in success when a publish retried after a version conflict works', async () => {
    const client = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
    client.setQueryData(key, snapshot)

    const fresh = { ...snapshot, version: 2 } as CloudSnapshot
    const publish = vi
      .fn()
      .mockRejectedValueOnce(new ApiError('stale', 'STALE_VERSION', 412))
      .mockResolvedValueOnce({ ...snapshot, version: 3 } as CloudSnapshot)

    const { result } = renderHook(
      () =>
        useOptimisticMutation<CloudSnapshot, Vars>('s1', {
          queryKey: key,
          fetchSnapshot: async () => fresh,
          publish,
          optimisticUpdate: (old) => old,
        }),
      { wrapper: ({ children }) => <Providers client={client}>{children}</Providers> },
    )

    await act(async () => {
      await result.current.mutateAsync({ played: '1-0' })
    })

    // The save worked on the second attempt; the caller must not be told it
    // failed (FE-44).
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.isError).toBe(false)
    expect(publish).toHaveBeenCalledTimes(2)
    expect(client.getQueryData(key)).toEqual({ ...snapshot, version: 3 })
  })
})

describe('useOptimisticMutation rollback', () => {
  it('restores the pre-mutation cache value after a plain failure', async () => {
    const h = harness({
      initial: snapshot,
      publish: async () => {
        throw new Error('write failed')
      },
      optimisticUpdate: (old, vars) => ({ ...poke(old, vars), version: 99 }),
    })
    const seenByPublish: unknown[] = []
    h.publish.mockImplementation(async () => {
      seenByPublish.push(h.client.getQueryData(key))
      throw new Error('write failed')
    })

    await act(async () => {
      await expect(h.result.current.mutateAsync({ played: '1-0' })).rejects.toThrow('write failed')
    })

    // The cache held the optimistic value while the request was in flight...
    expect(seenByPublish[0]).toMatchObject({ version: 99, playedGames: ['1-0'] })
    // ...and the failure put the old value back instead of leaving a lie.
    expect(h.client.getQueryData(key)).toEqual(snapshot)
    expect(h.fetchSnapshot).not.toHaveBeenCalled()
  })

  it('re-rolls the edit onto the fresh snapshot when the server reports contention', async () => {
    const fresh = {
      ...snapshot,
      version: 5,
      playedGames: ['other-writer'],
    } as CloudSnapshot
    const h = harness({
      initial: snapshot,
      publish: async () => ({ ...snapshot, version: 6 }),
      fetchSnapshot: async () => fresh,
      optimisticUpdate: poke,
    })
    h.publish
      .mockRejectedValueOnce(new ApiError('busy', null, 429))
      .mockResolvedValueOnce({ ...snapshot, version: 6 } as CloudSnapshot)

    await act(async () => {
      await h.result.current.mutateAsync({ played: '1-0' })
    })

    expect(h.fetchSnapshot).toHaveBeenCalledWith('s1')
    expect(h.publish).toHaveBeenCalledTimes(2)
    // The retry starts from the version the server just returned and keeps the
    // other writer's edit; retrying from the optimistic cache would have
    // carried version 1 and dropped 'other-writer'.
    expect(h.publish.mock.calls[1][1]).toMatchObject({
      version: 5,
      playedGames: ['other-writer', '1-0'],
    })
    expect(h.client.getQueryData(key)).toEqual({ ...snapshot, version: 6 })
  })

  it('rejects a 412 whose fresh fetch returns nothing without retrying the publish', async () => {
    const h = harness({
      initial: snapshot,
      publish: async () => {
        throw new ApiError('stale', 'STALE_VERSION', 412)
      },
      fetchSnapshot: async () => null,
      optimisticUpdate: (old, vars) => ({ ...poke(old, vars), version: 77 }),
    })

    await act(async () => {
      await expect(h.result.current.mutateAsync({ played: '1-0' })).rejects.toMatchObject({
        status: 412,
      })
    })

    expect(h.publish).toHaveBeenCalledTimes(1)
    expect(h.fetchSnapshot).toHaveBeenCalledWith('s1')
    // The rollback at useOptimisticMutation.ts:105 puts the old value back, but
    // the onError refetch (l.110-113) then writes the `null` it fetched, so the
    // cache ends empty rather than holding the rolled-back snapshot.
    expect(h.client.getQueryData(key)).toBeNull()
  })
})

describe('useOptimisticMutation cache policy', () => {
  it('publishes without touching the cache when applyOptimistic is false', async () => {
    const h = harness({
      initial: snapshot,
      publish: async () => ({ ...snapshot, version: 2 }),
      optimisticUpdate: (old, vars) => ({ ...(old as CloudSnapshot), version: 98, ...poke(old, vars) }),
      applyOptimistic: false,
    })
    const seenByPublish: unknown[] = []
    h.publish.mockImplementation(async () => {
      seenByPublish.push(h.client.getQueryData(key))
      return { ...snapshot, version: 2 } as CloudSnapshot
    })

    await act(async () => {
      await h.result.current.mutateAsync({ played: '1-0' })
    })

    // A non-deterministic mutation (a random shuffle) must not pre-write a
    // result the server may compute differently.
    expect(seenByPublish[0]).toEqual(snapshot)
    expect(h.publish).toHaveBeenCalledTimes(1)
    expect(h.client.getQueryData(key)).toEqual({ ...snapshot, version: 2 })
  })

  it('refetches on a plain 500 only when refetchOnAnyError is set', async () => {
    const fresh = { ...snapshot, version: 7 } as CloudSnapshot
    const h = harness({
      initial: snapshot,
      publish: async () => {
        throw new ApiError('server exploded', null, 500)
      },
      fetchSnapshot: async () => fresh,
      refetchOnAnyError: true,
    })

    await act(async () => {
      await expect(h.result.current.mutateAsync({ played: '1-0' })).rejects.toMatchObject({
        status: 500,
      })
    })

    expect(h.fetchSnapshot).toHaveBeenCalledWith('s1')
    expect(h.client.getQueryData(key)).toEqual(fresh)
  })

  it('skips the refetch for a plain 500 by default', async () => {
    const h = harness({
      initial: snapshot,
      publish: async () => {
        throw new ApiError('server exploded', null, 500)
      },
      fetchSnapshot: async () => ({ ...snapshot, version: 7 }),
    })

    await act(async () => {
      await expect(h.result.current.mutateAsync({ played: '1-0' })).rejects.toMatchObject({
        status: 500,
      })
    })

    expect(h.fetchSnapshot).not.toHaveBeenCalled()
    expect(h.client.getQueryData(key)).toEqual(snapshot)
  })

  it('runs onSuccessCallback after the cache already holds the server response', async () => {
    const server = { ...snapshot, version: 2, playedGames: ['server-says'] } as CloudSnapshot
    let cacheInCallback: unknown
    const h = harness({
      initial: snapshot,
      publish: async () => server,
      onSuccessCallback: async () => {
        cacheInCallback = h.client.getQueryData(key)
      },
    })

    await act(async () => {
      await h.result.current.mutateAsync({ played: '1-0' })
    })

    expect(cacheInCallback).toEqual(server)
    expect(h.client.getQueryData(key)).toEqual(server)
  })
})