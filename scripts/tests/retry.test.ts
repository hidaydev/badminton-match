import test from 'node:test'
import assert from 'node:assert/strict'
import {
  isRetryableError,
  MAX_RETRY_AFTER_SECONDS,
  parseRetryAfter,
  ApiError,
  shouldRetry,
} from '../../src/queries/retry.ts'

/** Simulate a network-level fetch failure (request never sent). */
function networkError(): TypeError {
  return new TypeError('Failed to fetch')
}

/** Simulate a timeout abort. */
function abortError(): DOMException {
  return new DOMException('The operation was aborted', 'AbortError')
}

// ── shouldRetry: policy method × error ───────────────────────────────────

test('GET 500 → retry', () => {
  assert.equal(shouldRetry('GET', new ApiError('boom', '500', 500), 0, 3), true)
})

test('GET 503 → retry', () => {
  assert.equal(shouldRetry('GET', new ApiError('unavailable', '503', 503), 0, 3), true)
})

test('GET 429 → retry', () => {
  assert.equal(shouldRetry('GET', new ApiError('rate limited', '429', 429), 0, 3), true)
})

test('PUT 500 → no retry (server may have applied the write)', () => {
  assert.equal(shouldRetry('PUT', new ApiError('boom', '500', 500), 0, 3), false)
})

test('POST 503 → no retry', () => {
  assert.equal(shouldRetry('POST', new ApiError('unavailable', '503', 503), 0, 3), false)
})

test('PATCH 500 → no retry', () => {
  assert.equal(shouldRetry('PATCH', new ApiError('boom', '500', 500), 0, 3), false)
})

test('DELETE 500 → no retry', () => {
  assert.equal(shouldRetry('DELETE', new ApiError('boom', '500', 500), 0, 3), false)
})

test('PUT 429 → retry (rate limit, request not applied)', () => {
  assert.equal(shouldRetry('PUT', new ApiError('rate limited', '429', 429), 0, 3), true)
})

test('POST 429 → retry', () => {
  assert.equal(shouldRetry('POST', new ApiError('rate limited', '429', 429), 0, 3), true)
})

test('PUT TypeError (fetch failed) → retry (request never sent)', () => {
  assert.equal(shouldRetry('PUT', networkError(), 0, 3), true)
})

test('GET TypeError (fetch failed) → retry', () => {
  assert.equal(shouldRetry('GET', networkError(), 0, 3), true)
})

test('AbortError → no retry for mutations', () => {
  assert.equal(shouldRetry('PUT', abortError(), 0, 3), false)
})

test('AbortError → no retry for reads either', () => {
  assert.equal(shouldRetry('GET', abortError(), 0, 3), false)
})

test('attempt == maxRetries → no retry', () => {
  assert.equal(shouldRetry('GET', new ApiError('boom', '500', 500), 3, 3), false)
  assert.equal(shouldRetry('GET', new ApiError('rate limited', '429', 429), 3, 3), false)
  assert.equal(shouldRetry('PUT', networkError(), 3, 3), false)
})

test('non-retryable errors → no retry', () => {
  assert.equal(shouldRetry('GET', new ApiError('not found', 'not_found', 404), 0, 3), false)
  assert.equal(shouldRetry('PUT', new ApiError('version mismatch', '40001', 409), 0, 3), false)
  assert.equal(shouldRetry('GET', new Error('plain error'), 0, 3), false)
})

// ── parseRetryAfter ──────────────────────────────────────────────────────

test('parseRetryAfter: numeric seconds', () => {
  assert.equal(parseRetryAfter('5'), 5)
  assert.equal(parseRetryAfter(' 2 '), 2)
  assert.equal(parseRetryAfter('0'), 0)
})

test('parseRetryAfter: capped at MAX_RETRY_AFTER_SECONDS', () => {
  assert.equal(parseRetryAfter('30'), MAX_RETRY_AFTER_SECONDS)
  assert.equal(parseRetryAfter('3600'), MAX_RETRY_AFTER_SECONDS)
})

test('parseRetryAfter: HTTP-date form', () => {
  const future = new Date(Date.now() + 7_000)
  const seconds = parseRetryAfter(future.toUTCString())
  assert.ok(seconds !== null && seconds >= 6 && seconds <= 8)
})

test('parseRetryAfter: missing or unparseable → null', () => {
  assert.equal(parseRetryAfter(null), null)
  assert.equal(parseRetryAfter(undefined), null)
  assert.equal(parseRetryAfter(''), null)
  assert.equal(parseRetryAfter('   '), null)
  assert.equal(parseRetryAfter('not-a-date'), null)
})

// ── isRetryableError ─────────────────────────────────────────────────────

test('isRetryableError: transport-level classification', () => {
  assert.equal(isRetryableError(new ApiError('x', '429', 429)), true)
  assert.equal(isRetryableError(new ApiError('x', '503', 503)), true)
  assert.equal(isRetryableError(new ApiError('x', '500', 500)), true)
  assert.equal(isRetryableError(new ApiError('x', '40001', 409)), false)
  assert.equal(isRetryableError(networkError()), true)
  assert.equal(isRetryableError(abortError()), false)
})
