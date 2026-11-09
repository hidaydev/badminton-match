import { beforeEach, describe, expect, it, vi } from 'vitest'
import {
  MATCH_KEYS,
  parseMatchSnapshot,
  readMatchSnapshot,
  serializeMatchSnapshot,
  shareMatchExport,
} from './matchExport'
import { resetStorageStatus } from './storage'

beforeEach(() => {
  resetStorageStatus()
  localStorage.clear()
  Reflect.deleteProperty(navigator, 'share')
  Reflect.deleteProperty(navigator, 'clipboard')
})

describe('matchExport', () => {
  it('round-trips the four stored keys through JSON', () => {
    localStorage.setItem('score-red', '7')
    localStorage.setItem('score-blue', '3')
    localStorage.setItem('name-red', 'Arya')
    localStorage.setItem('name-blue', 'Bowo')

    const snapshot = readMatchSnapshot()
    const restored = parseMatchSnapshot(serializeMatchSnapshot(snapshot))

    expect(restored).toEqual(snapshot)
    for (const key of MATCH_KEYS) {
      expect(restored?.[key]).toBe(localStorage.getItem(key))
    }
  })

  it('exports defaults for keys that were never written', () => {
    expect(readMatchSnapshot()).toEqual({
      'score-red': '0',
      'score-blue': '0',
      'name-red': '',
      'name-blue': '',
    })
  })

  it('rejects JSON that is not the four-key snapshot', () => {
    expect(parseMatchSnapshot('not json')).toBeNull()
    expect(parseMatchSnapshot('[]')).toBeNull()
    expect(parseMatchSnapshot('{"score-red":"1"}')).toBeNull()
    expect(parseMatchSnapshot('{"score-red":1,"score-blue":"0","name-red":"","name-blue":""}')).toBeNull()
  })

  it('shares the text through the native sheet when it exists', async () => {
    const share = vi.fn(async () => {})
    Object.defineProperty(navigator, 'share', { value: share, configurable: true })

    await expect(shareMatchExport('{"score-red":"1"}')).resolves.toBe('shared')
    expect(share).toHaveBeenCalledWith({ title: 'MAJADU Score', text: '{"score-red":"1"}' })
  })

  it('treats a cancelled share sheet as a cancellation, not a failure', async () => {
    const share = vi.fn(async () => {
      throw new DOMException('cancelled', 'AbortError')
    })
    Object.defineProperty(navigator, 'share', { value: share, configurable: true })

    await expect(shareMatchExport('{}')).resolves.toBe('cancelled')
  })

  it('falls back to the clipboard when the share sheet is unavailable', async () => {
    const writeText = vi.fn(async () => {})
    Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true })

    await expect(shareMatchExport('{"score-red":"1"}')).resolves.toBe('copied')
    expect(writeText).toHaveBeenCalledWith('{"score-red":"1"}')
  })

  it('reports a failure when neither path can copy the text', async () => {
    await expect(shareMatchExport('{}')).resolves.toBe('failed')

    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText: vi.fn(async () => { throw new Error('denied') }) },
      configurable: true,
    })
    await expect(shareMatchExport('{}')).resolves.toBe('failed')
  })
})
