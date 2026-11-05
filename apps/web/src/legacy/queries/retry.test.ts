import { describe, expect, it } from 'vitest'
import { ApiError } from '../../api/errors'
import { MAX_RETRY_AFTER_SECONDS, parseRetryAfter, shouldRetry } from './retry'

const MAX = 3

describe('shouldRetry', () => {
  it('retries a read on 500, 503 and 429', () => {
    for (const status of [500, 503, 429]) {
      expect(shouldRetry('GET', new ApiError('failed', null, status), 0, MAX)).toBe(true)
    }
  })

  it('retries a mutation only on 429, never on 5xx', () => {
    // A 5xx may have applied the write already; replaying it would double-apply.
    expect(shouldRetry('POST', new ApiError('failed', null, 500), 0, MAX)).toBe(false)
    expect(shouldRetry('PATCH', new ApiError('failed', null, 503), 0, MAX)).toBe(false)
    expect(shouldRetry('DELETE', new ApiError('failed', null, 429), 0, MAX)).toBe(true)
  })

  it('never retries a definitive answer', () => {
    for (const status of [400, 401, 403, 404, 409, 410, 412]) {
      expect(shouldRetry('GET', new ApiError('failed', null, status), 0, MAX)).toBe(false)
      expect(shouldRetry('POST', new ApiError('failed', null, status), 0, MAX)).toBe(false)
    }
  })

  it('retries a connection failure but not an abort', () => {
    expect(shouldRetry('POST', new TypeError('Failed to fetch'), 0, MAX)).toBe(true)
    expect(shouldRetry('GET', new DOMException('aborted', 'AbortError'), 0, MAX)).toBe(false)
  })

  it('stops once the attempt budget is spent', () => {
    expect(shouldRetry('GET', new ApiError('failed', null, 503), MAX, MAX)).toBe(false)
  })
})

describe('parseRetryAfter', () => {
  it('reads a delta in seconds', () => {
    expect(parseRetryAfter('4')).toBe(4)
    expect(parseRetryAfter(' 0 ')).toBe(0)
  })

  it('caps an unreasonable wait', () => {
    expect(parseRetryAfter('3600')).toBe(MAX_RETRY_AFTER_SECONDS)
  })

  it('reads an HTTP date relative to now', () => {
    const at = new Date(Date.now() + 5_000).toUTCString()
    expect(parseRetryAfter(at)).toBe(5)
    const past = new Date(Date.now() - 60_000).toUTCString()
    expect(parseRetryAfter(past)).toBe(0)
  })

  it('returns null for a missing or unparseable header', () => {
    expect(parseRetryAfter(null)).toBeNull()
    expect(parseRetryAfter(undefined)).toBeNull()
    expect(parseRetryAfter('')).toBeNull()
    expect(parseRetryAfter('soon')).toBeNull()
  })
})