import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { vi } from 'vitest'
import { mockFetch } from '../../test/fetchMock'
import { getPlayerAchievements, setCommunitySlug } from './endpoints'

const items = [
  {
    key: 'streak:8',
    category: 'attendance',
    threshold: 8,
    earnedAt: '2026-10-01T00:00:00Z',
    title: 'Streak 8',
    value: 8,
    tierLevel: 3,
    tierName: 'Gold',
    nextTarget: 12,
    thresholds: [3, 5, 8, 12, 16],
    meta: { metric: 'streak' },
  },
  {
    key: 'streak:3',
    category: 'attendance',
    threshold: 3,
    earnedAt: '2026-09-01T00:00:00Z',
    title: 'Streak 3',
    value: 3,
    tierLevel: 1,
    tierName: 'Bronze',
    nextTarget: 5,
    thresholds: [3, 5, 8, 12, 16],
    meta: { metric: 'streak' },
  },
  {
    key: 'rank:5',
    category: 'rank',
    threshold: 5,
    earnedAt: '2026-09-01T00:00:00Z',
    title: 'Rank Top 5',
    value: 5,
    tierLevel: 2,
    nextTarget: 3,
    thresholds: [10, 5, 3, 2, 1],
    meta: { metric: 'rank' },
  },
  {
    key: 'rank:2',
    category: 'rank',
    threshold: 2,
    earnedAt: '2026-09-02T00:00:00Z',
    title: 'Rank Top 2',
    value: 2,
    tierLevel: 4,
    nextTarget: 1,
    thresholds: [10, 5, 3, 2, 1],
    meta: { metric: 'rank' },
  },
  {
    key: 'rank_streak:11',
    category: 'rank',
    threshold: 11,
    earnedAt: '2026-09-03T00:00:00Z',
    title: 'Rank streak 11',
    value: 11,
    tierLevel: 3,
    nextTarget: 12,
    thresholds: [3, 5, 8, 12, 16],
    meta: { metric: 'rank_streak' },
  },
  {
    key: 'tier:B',
    category: 'tier',
    threshold: 5,
    earnedAt: '2026-09-03T00:00:00Z',
    title: 'Tier B',
    value: 5,
    meta: { metric: 'tier' },
  },
  {
    key: 'tournaments:1',
    category: 'tournament',
    threshold: 1,
    earnedAt: '2026-09-03T00:00:00Z',
    title: 'Tournaments 1',
    value: 1,
    meta: { metric: 'tournaments' },
  },
  {
    key: 'tournament:event-1',
    category: 'tournament',
    threshold: 0,
    earnedAt: '2026-09-04T00:00:00Z',
    title: 'MAJADU 1st Anniversary',
    value: 0,
    meta: { name: 'MAJADU 1st Anniversary' },
  },
]

describe('legacy achievements', () => {
  beforeEach(() => {
    setCommunitySlug('majadu')
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('collapses v2 threshold rows into one v1 badge per family', async () => {
    mockFetch({
      'GET /api/c/majadu/players/p1/achievements': () => ({ body: { items } }),
    })
    const rows = await getPlayerAchievements('p1')
    const keys = rows.map((row) => row.key)
    // Duplicate families keep only the best rung; rank improves downward.
    expect(keys.filter((key) => key === 'medal:streak')).toHaveLength(1)
    expect(keys.filter((key) => key === 'medal:rank')).toHaveLength(1)
    expect(rows.find((row) => row.key === 'medal:streak')?.value).toBe(8)
    expect(rows.find((row) => row.key === 'medal:rank')?.value).toBe(2)
    // v1 had no tier or tournament-count badge; event medals stay as-is.
    expect(keys).not.toContain('medal:tier')
    expect(keys).not.toContain('medal:tournaments')
    expect(keys).toContain('medal:rank_streak')
    expect(keys).toContain('tournament:event-1')
    expect(rows.find((row) => row.key === 'tournament:event-1')?.title).toBe(
      'MAJADU 1st Anniversary',
    )
  })
})
