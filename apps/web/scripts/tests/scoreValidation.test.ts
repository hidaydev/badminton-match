import test from 'node:test'
import assert from 'node:assert/strict'
import { validateScore } from '../../src/utils/scoreValidation.ts'

// Boundary cases — MIRROR TestValidateScore di
// majadu-api/internal/domain/transform_test.go. Jaga kedua sisi tetap konsisten.
test('skor valid', () => {
  assert.equal(validateScore(21, 18), null)
  assert.equal(validateScore(0, 5), null)
  assert.equal(validateScore(99, 98), null)
})

test('skor sama → ditolak', () => {
  assert.ok(validateScore(0, 0)?.includes('equal'))
  assert.ok(validateScore(21, 21)?.includes('equal'))
})

test('skor negatif → ditolak', () => {
  assert.ok(validateScore(-1, 5)?.includes('negative'))
  assert.ok(validateScore(-2, -3)?.includes('negative'))
})

test('skor > 99 → ditolak (parity dengan backend)', () => {
  assert.ok(validateScore(100, 15)?.includes('99'))
  assert.ok(validateScore(15, 100)?.includes('99'))
})
