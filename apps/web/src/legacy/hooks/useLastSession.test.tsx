import { beforeEach, describe, expect, it, vi } from 'vitest'
import { renderHook } from '@testing-library/react'
import { useLastSession, type LastSessionMeta } from './useLastSession'

const LS_KEY = 'last-visited-session'

const meta: LastSessionMeta = {
  id: 's1',
  slug: 'jakarta',
  title: 'Tuesday Night',
  date: '2026-11-03',
  playerCount: 8,
  totalGames: 6,
  locked: false,
}

describe('useLastSession', () => {
  beforeEach(() => {
    window.localStorage.clear()
  })

  it('writes only when the stored session changes', () => {
    const setItem = vi.spyOn(Storage.prototype, 'setItem')
    const { result, rerender } = renderHook(() => useLastSession())

    result.current.save(meta)
    expect(setItem).toHaveBeenCalledTimes(1)

    rerender()
    result.current.save({ ...meta })
    expect(setItem).toHaveBeenCalledTimes(1)

    result.current.save({ ...meta, title: 'Moved court' })
    expect(setItem).toHaveBeenCalledTimes(2)
    setItem.mockRestore()
  })

  it('reads the stored session once, not on every render', () => {
    window.localStorage.setItem(LS_KEY, JSON.stringify(meta))
    const { result, rerender } = renderHook(() => useLastSession())
    expect(result.current.lastSession).toEqual(meta)

    window.localStorage.removeItem(LS_KEY)
    rerender()
    expect(result.current.lastSession).toEqual(meta)
  })

  it('stores the community slug next to the session id', () => {
    const { result } = renderHook(() => useLastSession())
    result.current.save(meta)

    expect(JSON.parse(window.localStorage.getItem(LS_KEY) ?? '{}')).toEqual(meta)
  })

  it('ignores a session stored before the slug was added', () => {
    const legacy: Record<string, unknown> = { ...meta }
    delete legacy.slug
    window.localStorage.setItem(LS_KEY, JSON.stringify(legacy))

    const { result } = renderHook(() => useLastSession())
    expect(result.current.lastSession).toBeNull()
  })
})