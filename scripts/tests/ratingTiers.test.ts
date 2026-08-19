import test from 'node:test'
import assert from 'node:assert/strict'
import { RATING_TIER_BADGE_COLORS, type RatingClass } from '../../src/config/ratingTiers.ts'

// Kelas rating 12 sub-tier (D-..A+) — warna lengkap untuk semua band.
const CLASSES: RatingClass[] = ['D-', 'D', 'D+', 'C-', 'C', 'C+', 'B-', 'B', 'B+', 'A-', 'A', 'A+']

test('ratingTiers: 12 kelas lengkap dengan warna', () => {
  assert.equal(CLASSES.length, 12)
  for (const c of CLASSES) {
    assert.ok(RATING_TIER_BADGE_COLORS[c], `kelas ${c} tidak punya warna`)
    assert.ok(RATING_TIER_BADGE_COLORS[c].includes('border'), `kelas ${c} tanpa border color`)
  }
})

test('ratingTiers: fallback aman untuk kelas tak dikenal', () => {
  assert.equal(
    RATING_TIER_BADGE_COLORS['ZZ' as RatingClass] ?? RATING_TIER_BADGE_COLORS['D-'],
    RATING_TIER_BADGE_COLORS['D-'],
  )
})
