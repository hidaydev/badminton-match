import test from 'node:test'
import assert from 'node:assert/strict'
import { isPlaceholderName } from '../../src/utils/placeholders.ts'

// MIRROR majadu-api/internal/domain/placeholder_test.go — jaga konsisten.
test('isPlaceholderName: pola placeholder terdeteksi', () => {
  assert.equal(isPlaceholderName('free'), true)
  assert.equal(isPlaceholderName('Free'), true)
  assert.equal(isPlaceholderName('free 1'), true)
  assert.equal(isPlaceholderName('free 12'), true)
  assert.equal(isPlaceholderName('tbd'), true)
  assert.equal(isPlaceholderName('TBD 2'), true)
  assert.equal(isPlaceholderName('default'), true)
  assert.equal(isPlaceholderName('default 3'), true)
  assert.equal(isPlaceholderName('xxx'), true)
  assert.equal(isPlaceholderName('unknown'), true)
  assert.equal(isPlaceholderName('kosong'), true)
  assert.equal(isPlaceholderName('belum ada'), true)
  assert.equal(isPlaceholderName('?'), true)
  assert.equal(isPlaceholderName('???'), true)
  assert.equal(isPlaceholderName('  free 1  '), true) // whitespace dinormalisasi
})

test('isPlaceholderName: nama asli tidak terdeteksi', () => {
  assert.equal(isPlaceholderName(''), false)
  assert.equal(isPlaceholderName('   '), false)
  assert.equal(isPlaceholderName('freedy'), false)
  assert.equal(isPlaceholderName('tbdoto'), false)
  assert.equal(isPlaceholderName('defaults'), false)
  assert.equal(isPlaceholderName('Xander'), false)
  assert.equal(isPlaceholderName('Azzam & Zainal'), false)
  assert.equal(isPlaceholderName('unknownplayer'), false)
})
