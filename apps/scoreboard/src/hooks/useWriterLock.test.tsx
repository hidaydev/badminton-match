import { afterEach, describe, expect, it, vi } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { useWriterLock, WRITER_LOCK } from './useWriterLock'

type Request = (
  name: string,
  options: { ifAvailable: boolean; signal: AbortSignal },
  callback: (lock: object | null) => Promise<void> | void,
) => Promise<void>

function setLocks(granted: boolean) {
  const request = vi.fn<Request>((name, _options, callback) => {
    expect(name).toBe(WRITER_LOCK)
    return Promise.resolve(callback(granted ? {} : null))
  })
  Object.defineProperty(navigator, 'locks', { value: { request }, configurable: true })
  return request
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

  it('releases the lock on unmount', async () => {
    const request = setLocks(true)
    const { unmount } = renderHook(() => useWriterLock())
    await waitFor(() => expect(request).toHaveBeenCalledTimes(1))

    // The held lock is the pending promise; aborting is what frees it.
    unmount()
    const options = request.mock.calls[0][1]
    expect(options.signal.aborted).toBe(true)
  })
})
