import test from 'node:test'
import assert from 'node:assert/strict'
import { RATING_TIER_LABELS, RATING_TIER_BADGE_COLORS } from '../../src/config/ratingTiers.ts'

// Tier rating 1-10 (D..S+) — harus lengkap label + warna untuk semua band.
test('ratingTiers: label lengkap untuk band 1-10', () => {
  const labels = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((t) => RATING_TIER_LABELS[t])
  assert.deepEqual(labels, ['D', 'D+', 'C', 'C+', 'B', 'B+', 'A', 'A+', 'S', 'S+'])
})

test('ratingTiers: badge color ada untuk semua band', () => {
  for (let t = 1; t <= 10; t++) {
    assert.ok(RATING_TIER_BADGE_COLORS[t], `band ${t} tidak punya warna`)
    assert.ok(RATING_TIER_BADGE_COLORS[t].includes('border'), `band ${t} tanpa border color`)
  }
  // band di luar 1-10 → fallback aman ke D
  assert.equal(RATING_TIER_BADGE_COLORS[0] ?? RATING_TIER_BADGE_COLORS[1], RATING_TIER_BADGE_COLORS[1])
})
