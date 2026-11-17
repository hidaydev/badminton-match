import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mockFetch } from '../../test/fetchMock'
import { getPlayerAchievements, setCommunitySlug } from './endpoints'

/**
 * Medal families that the written product rules put on the player shelf:
 *
 * - `docs/handbook/product-overview.md` §4 lists `tournament` and `tier` among
 *   the badge categories and says the badges appear at
 *   `/c/{slug}/rankings/{playerId}`.
 * - `ops/dev/v1/fixtures/v1-fixtures.sql:68` stores a v1 `medal:tournaments`
 *   row (value 2), and `tools/import/main.nim` expands it into `tournaments:1`.
 *
 * So both families exist before the cutover and after it. This file asks the
 * adapter for them; the existing `endpoints.test.ts` asserts the opposite.
 */
const items = [
  {
    key: 'tournaments:1',
    category: 'tournament',
    threshold: 1,
    earnedAt: '2026-10-18T07:07:00Z',
    title: 'Tournaments 1',
    detail: 'Join 1 tournaments.',
    value: 1,
    tierLevel: 1,
    tierName: 'Bronze',
    nextTarget: 3,
    thresholds: [1, 3, 5],
    meta: { metric: 'tournaments', source: 'v1' },
  },
  {
    key: 'tier:B',
    category: 'tier',
    threshold: 5,
    earnedAt: '2026-10-18T07:07:00Z',
    title: 'Tier B',
    detail: 'Reach tier B.',
    value: 5,
    tierLevel: null,
    tierName: null,
    nextTarget: null,
    thresholds: [5],
    meta: { metric: 'tier', tier: 'B' },
  },
]

describe('medal families on the player shelf', () => {
  beforeEach(() => {
    setCommunitySlug('majadu')
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('keeps the v1 tournament-count medal that the import carries over', async () => {
    mockFetch({
      'GET /api/c/majadu/players/p1/achievements': () => ({ body: { items } }),
    })
    const rows = await getPlayerAchievements('p1')
    expect(rows.map((row) => row.key)).toContain('medal:tournaments')
  })

  it('shows the tier badge the catalogue awards', async () => {
    mockFetch({
      'GET /api/c/majadu/players/p1/achievements': () => ({ body: { items } }),
    })
    const rows = await getPlayerAchievements('p1')
    expect(rows.map((row) => row.key)).toContain('medal:tier')
  })
})
