import test from 'node:test'
import assert from 'node:assert/strict'
import {
  ApiError,
  isRetryableError,
  shouldRetry,
  parseRetryAfter,
  MAX_RETRY_AFTER_SECONDS,
} from '../../src/queries/retry.ts'

// ── ApiError ──────────────────────────────────────────────────────────────

test('ApiError membawa code dan status', () => {
  const err = new ApiError('boom', 'conflict', 409)
  assert.equal(err.name, 'ApiError')
  assert.equal(err.code, 'conflict')
  assert.equal(err.status, 409)
  assert.ok(err instanceof Error)
})

// ── isRetryableError (level transport, tanpa method) ──────────────────────

test('isRetryableError: status transient → true', () => {
  assert.equal(isRetryableError(new ApiError('x', 'r1', 429)), true)
  assert.equal(isRetryableError(new ApiError('x', 'r2', 500)), true)
  assert.equal(isRetryableError(new ApiError('x', 'r3', 503)), true)
})

test('isRetryableError: status non-transient → false', () => {
  assert.equal(isRetryableError(new ApiError('x', '40001', 409)), false)
  assert.equal(isRetryableError(new ApiError('x', 'not_found', 404)), false)
  assert.equal(isRetryableError(new ApiError('x', 'v', 422)), false)
})

test('isRetryableError: network failure sebelum terkirim → true', () => {
  assert.equal(isRetryableError(new TypeError('fetch failed')), true)
})

test('isRetryableError: AbortError (timeout) → false', () => {
  assert.equal(isRetryableError(new DOMException('timeout', 'AbortError')), false)
})

test('isRetryableError: error lain → false', () => {
  assert.equal(isRetryableError(new Error('plain')), false)
})

// ── shouldRetry (method-aware) ────────────────────────────────────────────

test('read: retry pada 429/503/500 + network', () => {
  assert.equal(shouldRetry('GET', new ApiError('x', 'r1', 429), 0, 3), true)
  assert.equal(shouldRetry('GET', new ApiError('x', 'r2', 503), 0, 3), true)
  assert.equal(shouldRetry('GET', new ApiError('x', 'r3', 500), 0, 3), true)
  assert.equal(shouldRetry('GET', new TypeError('fetch failed'), 0, 3), true)
})

test('read: tidak retry 4xx non-429 / AbortError', () => {
  assert.equal(shouldRetry('GET', new ApiError('x', 'nf', 404), 0, 3), false)
  assert.equal(shouldRetry('GET', new DOMException('timeout', 'AbortError'), 0, 3), false)
})

test('mutation: retry hanya 429 dan network-pre-send', () => {
  assert.equal(shouldRetry('PUT', new ApiError('x', 'rl', 429), 0, 3), true)
  assert.equal(shouldRetry('POST', new TypeError('fetch failed'), 0, 3), true)
})

test('mutation: TIDAK retry 5xx (server mungkin sudah apply)', () => {
  assert.equal(shouldRetry('PUT', new ApiError('x', 'e500', 500), 0, 3), false)
  assert.equal(shouldRetry('POST', new ApiError('x', 'e503', 503), 0, 3), false)
  assert.equal(shouldRetry('PATCH', new ApiError('x', 'e500', 500), 0, 3), false)
  assert.equal(shouldRetry('DELETE', new ApiError('x', 'e500', 500), 0, 3), false)
})

test('mutation: TIDAK retry timeout (server mungkin sudah apply)', () => {
  assert.equal(shouldRetry('PUT', new DOMException('timeout', 'AbortError'), 0, 3), false)
})

test('attempt >= maxRetries → tidak retry', () => {
  assert.equal(shouldRetry('GET', new ApiError('x', 'r1', 500), 3, 3), false)
  assert.equal(shouldRetry('GET', new ApiError('x', 'r2', 429), 3, 3), false)
})

// ── parseRetryAfter ───────────────────────────────────────────────────────

test('parseRetryAfter: detik numerik', () => {
  assert.equal(parseRetryAfter('5'), 5)
})

test('parseRetryAfter: dikap ke MAX_RETRY_AFTER_SECONDS', () => {
  assert.equal(parseRetryAfter('3600'), MAX_RETRY_AFTER_SECONDS)
})

test('parseRetryAfter: HTTP-date', () => {
  const future = new Date(Date.now() + 4000)
  const value = parseRetryAfter(future.toUTCString())
  assert.ok(value !== null && value >= 1 && value <= 10, `got ${value}`)
})

test('parseRetryAfter: kosong / tidak valid → null', () => {
  assert.equal(parseRetryAfter(null), null)
  assert.equal(parseRetryAfter(undefined), null)
  assert.equal(parseRetryAfter('  '), null)
  assert.equal(parseRetryAfter('abc'), null)
})
