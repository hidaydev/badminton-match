import test from 'node:test'
import assert from 'node:assert/strict'
import { isChunkLoadError } from '../../src/utils/safeLazy.ts'

test('isChunkLoadError: mendeteksi nama error ChunkLoadError', () => {
  const err = new Error('Loading chunk 123 failed.')
  err.name = 'ChunkLoadError'
  assert.equal(isChunkLoadError(err), true)
})

test('isChunkLoadError: mendeteksi pesan Failed to fetch dynamically imported module', () => {
  const err = new TypeError('Failed to fetch dynamically imported module: https://majadu.vercel.app/assets/RatingsPage-B38RCPUd.js')
  assert.equal(isChunkLoadError(err), true)
})

test('isChunkLoadError: mendeteksi pesan error loading dynamically imported module', () => {
  const err = new Error('error loading dynamically imported module https://majadu.vercel.app/assets/RatingsPage-B38RCPUd.js')
  assert.equal(isChunkLoadError(err), true)
})

test('isChunkLoadError: mendeteksi pesan importing a module script failed', () => {
  const err = new Error('Importing a module script failed.')
  assert.equal(isChunkLoadError(err), true)
})

test('isChunkLoadError: return false untuk error biasa', () => {
  const err = new Error('Cannot read property of undefined')
  assert.equal(isChunkLoadError(err), false)
  assert.equal(isChunkLoadError(null), false)
  assert.equal(isChunkLoadError(undefined), false)
})
