import test from 'node:test'
import assert from 'node:assert/strict'
import { RATING_TIER_BADGE_COLORS, type RatingTier } from '../../src/config/ratingTiers.ts'

// Tier rating 8-band (TIER_8_UNIFICATION.md §3.2) — warna lengkap semua band.
const TIERS: RatingTier[] = ['D', 'D+', 'C', 'C+', 'B', 'B+', 'A', 'A+']

test('ratingTiers: 8 tier lengkap dengan warna', () => {
  assert.equal(TIERS.length, 8)
  for (const t of TIERS) {
    assert.ok(RATING_TIER_BADGE_COLORS[t], `tier ${t} tidak punya warna`)
    assert.ok(RATING_TIER_BADGE_COLORS[t].includes('border'), `tier ${t} tanpa border color`)
  }
})

test('ratingTiers: fallback aman untuk tier tak dikenal', () => {
  assert.equal(
    RATING_TIER_BADGE_COLORS['ZZ' as RatingTier] ?? RATING_TIER_BADGE_COLORS['D'],
    RATING_TIER_BADGE_COLORS['D'],
  )
})
