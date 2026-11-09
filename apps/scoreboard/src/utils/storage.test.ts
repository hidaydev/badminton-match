import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  isStorageUnavailable,
  readStoredValue,
  resetStorageStatus,
  subscribeStorageStatus,
  writeStoredValue,
} from './storage'

beforeEach(() => {
  resetStorageStatus()
  localStorage.clear()
})

describe('storage', () => {
  it('reads and writes through localStorage while it works', () => {
    writeStoredValue('score-red', '3')

    expect(localStorage.getItem('score-red')).toBe('3')
    expect(readStoredValue('score-red')).toBe('3')
    expect(isStorageUnavailable()).toBe(false)
  })

  it('falls back to memory when a read throws and notifies subscribers once', () => {
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new DOMException('blocked', 'SecurityError')
    })
    const listener = vi.fn()
    const unsubscribe = subscribeStorageStatus(listener)

    expect(readStoredValue('score-red')).toBeNull()
    expect(readStoredValue('score-blue')).toBeNull()
    expect(isStorageUnavailable()).toBe(true)
    expect(listener).toHaveBeenCalledTimes(1)

    unsubscribe()
  })

  it('keeps writes in memory when setItem throws', () => {
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new DOMException('full', 'QuotaExceededError')
    })

    writeStoredValue('score-red', '5')

    expect(readStoredValue('score-red')).toBe('5')
    expect(isStorageUnavailable()).toBe(true)
  })

  it('stops notifying once the listener unsubscribes', () => {
    const listener = vi.fn()
    subscribeStorageStatus(listener)()
    vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new DOMException('blocked', 'SecurityError')
    })

    readStoredValue('score-red')

    expect(listener).not.toHaveBeenCalled()
  })
})
