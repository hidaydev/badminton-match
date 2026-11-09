import { afterEach, describe, expect, it, vi } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { useWriterLock, WRITER_LOCK } from './useWriterLock'

type Request = (
  name: string,
  options: { ifAvailable: boolean },
  callback: (lock: object | null) => Promise<void> | void,
) => Promise<void>

function setLocks(granted: boolean) {
  const held: Promise<void>[] = []
  const request = vi.fn<Request>((name, _options, callback) => {
    expect(name).toBe(WRITER_LOCK)
    const result = callback(granted ? {} : null)
    if (result instanceof Promise) held.push(result)
    return Promise.resolve()
  })
  Object.defineProperty(navigator, 'locks', { value: { request }, configurable: true })
  return { request, held }
}

afterEach(() => {
  Reflect.deleteProperty(navigator, 'locks')
})

describe('useWriterLock', () => {
  it('stays writable when the Web Locks API is unavailable', () => {
    const { result } = renderHook(() => useWriterLock())
    expect(result.current).toBe(true)
  })

  it('is the writer when it is granted the lock', async () => {
    setLocks(true)
    const { result } = renderHook(() => useWriterLock())
    await waitFor(() => expect(result.current).toBe(true))
  })

  it('turns read-only when another document holds the lock', async () => {
    setLocks(false)
    const { result } = renderHook(() => useWriterLock())
    await waitFor(() => expect(result.current).toBe(false))
  })

  it('asks for the lock without the signal option browsers reject', async () => {
    const { request } = setLocks(true)
    renderHook(() => useWriterLock())
    await waitFor(() => expect(request).toHaveBeenCalledTimes(1))
    expect(request.mock.calls[0][1]).toEqual({ ifAvailable: true })
  })

  it('releases the lock on unmount', async () => {
    const { request, held } = setLocks(true)
    const { unmount } = renderHook(() => useWriterLock())
    await waitFor(() => expect(request).toHaveBeenCalledTimes(1))

    // The held lock is the promise the callback returned; resolving it is what
    // releases it.
    unmount()
    await expect(held[0]).resolves.toBeUndefined()
  })
})
