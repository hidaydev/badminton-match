import { describe, expect, it, vi } from 'vitest'
import { act, renderHook } from '@testing-library/react'
import { useAsyncEffect } from './useAsyncEffect'

describe('useAsyncEffect', () => {
  it('reports live while mounted and flips it before the teardown runs', async () => {
    const seen: boolean[] = []
    let resolve: ((value: string) => void) | null = null
    const pending = new Promise<string>((settle) => {
      resolve = settle
    })

    const { unmount } = renderHook(() =>
      useAsyncEffect((scope) => {
        seen.push(scope.live)
        void pending.then(() => {
          seen.push(scope.live)
        })
      }, []),
    )

    expect(seen).toEqual([true])
    unmount()
    await act(async () => {
      resolve?.('late answer')
      await pending
    })

    // The late answer reads the flag after cleanup, so the caller can skip its
    // state update. This is the guard every screen wrote by hand.
    expect(seen).toEqual([true, false])
  })

  it('runs registered teardowns once, in registration order, on cleanup', () => {
    const order: string[] = []
    const { unmount } = renderHook(() =>
      useAsyncEffect((scope) => {
        scope.onCleanup(() => order.push('timer'))
        scope.onCleanup(() => order.push('listener'))
      }, []),
    )

    expect(order).toEqual([])
    unmount()
    expect(order).toEqual(['timer', 'listener'])
  })

  it('starts a new scope when the dependency changes and cleans the old one up', () => {
    const scopes: boolean[] = []
    const teardowns = vi.fn()
    const { rerender } = renderHook(
      ({ key }: { key: number }) =>
        useAsyncEffect((scope) => {
          scopes.push(scope.live)
          scope.onCleanup(teardowns)
        }, [key]),
      { initialProps: { key: 1 } },
    )

    rerender({ key: 2 })

    expect(teardowns).toHaveBeenCalledTimes(1)
    expect(scopes).toEqual([true, true])
  })
})
