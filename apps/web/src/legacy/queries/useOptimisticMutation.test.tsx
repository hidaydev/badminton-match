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

describe('useOptimisticMutation retry', () => {
  it('ends in success when a publish retried after a version conflict works', async () => {
    const client = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
    const key = ['session', 's1']
    client.setQueryData(key, snapshot)

    const fresh = { ...snapshot, version: 2 } as CloudSnapshot
    const publish = vi
      .fn()
      .mockRejectedValueOnce(new ApiError('stale', 'STALE_VERSION', 412))
      .mockResolvedValueOnce({ ...snapshot, version: 3 } as CloudSnapshot)

    const { result } = renderHook(
      () =>
        useOptimisticMutation<CloudSnapshot, { played: string }>('s1', {
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