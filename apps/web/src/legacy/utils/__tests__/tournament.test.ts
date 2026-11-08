import { describe, expect, it } from 'vitest'
import {
  QF_IDS,
  SF_IDS,
  computeGroupStandings,
  generateGroupMatches,
  initKnockoutMatches,
  propagateBracket,
  type GroupId,
  type TournamentMatch,
} from '../tournament'

const groupMatch = (
  id: string,
  groupId: GroupId,
  pairAId: string,
  pairBId: string,
  scoreA: number,
  scoreB: number,
): TournamentMatch => ({
  id,
  phase: 'group',
  groupId,
  pairAId,
  pairBId,
  scoreA,
  scoreB,
})

const emptyGroups = (): Record<GroupId, string[]> => ({
  A: ['a1', 'a2', 'a3', 'a4'],
  B: ['b1', 'b2', 'b3', 'b4'],
  C: ['c1', 'c2', 'c3', 'c4'],
  D: ['d1', 'd2', 'd3', 'd4'],
})

describe('generateGroupMatches', () => {
  it('schedules each of the six pairings of a four-pair group exactly once', () => {
    const matches = generateGroupMatches('A', ['p1', 'p2', 'p3', 'p4'])

    expect(matches).toHaveLength(6)
    expect(matches.map((m) => [m.pairAId, m.pairBId])).toEqual([
      ['p1', 'p2'],
      ['p3', 'p4'],
      ['p1', 'p3'],
      ['p2', 'p4'],
      ['p1', 'p4'],
      ['p2', 'p3'],
    ])
    expect(matches.map((m) => m.id)).toEqual([
      'group-A-0',
      'group-A-1',
      'group-A-2',
      'group-A-3',
      'group-A-4',
      'group-A-5',
    ])
    expect(matches.every((m) => m.phase === 'group' && m.groupId === 'A')).toBe(true)
    expect(matches.every((m) => m.scoreA === null && m.scoreB === null)).toBe(true)
  })

  it('still emits all six fixed rows for a three-pair group (the table is not sized by n)', () => {
    // The round-robin table at tournament.ts:50 is a constant six rows, so a
    // short group leaves the last two rows without a second side instead of
    // producing n*(n-1)/2 = 3 rows.
    const matches = generateGroupMatches('B', ['p1', 'p2', 'p3'])

    expect(matches).toHaveLength(6)
    expect(matches.map((m) => m.pairAId)).toEqual(['p1', 'p3', 'p1', 'p2', 'p1', 'p2'])
    expect(matches.map((m) => m.pairBId ?? null)).toEqual(['p2', null, 'p3', null, null, 'p3'])
  })
})

describe('computeGroupStandings', () => {
  it('ranks by wins, then point difference, then points for', () => {
    // Three decided games: one 1-0 edge each, chosen so the three sort keys are
    // each the only thing separating one pair of rows.
    const matches = [
      groupMatch('g1', 'A', 'a', 'b', 30, 20), // a: 1W +10 30, b: 0W -10 20
      groupMatch('g2', 'A', 'c', 'd', 25, 15), // c: 1W +10 25, d: 0W -10 15
      groupMatch('g3', 'A', 'e', 'f', 30, 10), // e: 1W +20 30, f: 0W -20 10
    ]

    const rows = computeGroupStandings('A', ['a', 'b', 'c', 'd', 'e', 'f'], matches)

    // e outranks a and c on difference, a outranks c on points for.
    expect(rows.map((row) => row.pairId)).toEqual(['e', 'a', 'c', 'b', 'd', 'f'])
    expect(rows[0]).toMatchObject({ wins: 1, losses: 0, pointsFor: 30, pointsAgainst: 10, diff: 20 })
    expect(rows[2]).toMatchObject({ wins: 1, losses: 0, diff: 10, pointsFor: 25 })
  })

  it('ignores a group match that has no score yet', () => {
    const rows = computeGroupStandings('A', ['a', 'b'], [
      { id: 'g1', phase: 'group', groupId: 'A', pairAId: 'a', pairBId: 'b', scoreA: 12, scoreB: null },
    ])

    expect(rows.map((row) => [row.pairId, row.wins, row.losses])).toEqual([
      ['a', 0, 0],
      ['b', 0, 0],
    ])
  })
})

describe('propagateBracket', () => {
  it('fills the semifinal from the decided quarterfinal and leaves the other slot empty', () => {
    const seeded = propagateBracket(initKnockoutMatches(), emptyGroups())

    // Seeding: qf-1 A1 v B2, qf-2 C2 v D1, qf-3 C1 v D2, qf-4 A2 v B1.
    const [qf1, qf2, qf3, qf4] = QF_IDS.map((id) => seeded.find((m) => m.id === id)!)
    expect([qf1.pairAId, qf1.pairBId]).toEqual(['a1', 'b2'])
    expect([qf2.pairAId, qf2.pairBId]).toEqual(['c2', 'd1'])
    expect([qf3.pairAId, qf3.pairBId]).toEqual(['c1', 'd2'])
    expect([qf4.pairAId, qf4.pairBId]).toEqual(['a2', 'b1'])

    const scored = seeded.map((m) => {
      if (m.id === 'qf-1') return { ...m, scoreA: 30, scoreB: 20 }
      if (m.id === 'qf-2') return { ...m, scoreA: 20, scoreB: 30 }
      return m
    })

    const next = propagateBracket(scored, emptyGroups())
    const [sf1, sf2] = SF_IDS.map((id) => next.find((m) => m.id === id)!)

    expect([sf1.pairAId, sf1.pairBId]).toEqual(['a1', 'd1'])
    expect([sf2.pairAId, sf2.pairBId]).toEqual([null, null])
    // Undecided feeders keep the final empty too.
    expect(next.find((m) => m.id === 'final-1')).toMatchObject({ pairAId: null, pairBId: null })
  })

  it('replaces the propagated semifinalist when the quarterfinal is re-scored', () => {
    const scored = propagateBracket(initKnockoutMatches(), emptyGroups()).map((m) =>
      m.id === 'qf-1' ? { ...m, scoreA: 30, scoreB: 20 } : m,
    )
    const first = propagateBracket(scored, emptyGroups())
    expect(first.find((m) => m.id === 'sf-1')?.pairAId).toBe('a1')

    // The same quarterfinal now goes the other way: b2 wins instead of a1.
    const rescored = first.map((m) => (m.id === 'qf-1' ? { ...m, scoreA: 10, scoreB: 30 } : m))
    const again = propagateBracket(rescored, emptyGroups())

    const semifinals = again.filter((m) => m.id === 'sf-1')
    expect(semifinals).toHaveLength(1)
    expect(semifinals[0].pairAId).toBe('b2')
    expect(semifinals[0]).toMatchObject({ pairBId: null, scoreA: null, scoreB: null })
  })

  it('clears a semifinal score when its feeder changes', () => {
    const decided = propagateBracket(
      initKnockoutMatches().map((m) => {
        if (m.id === 'qf-1') return { ...m, pairAId: 'a1', pairBId: 'b2', scoreA: 30, scoreB: 20 }
        if (m.id === 'qf-2') return { ...m, pairAId: 'c2', pairBId: 'd1', scoreA: 20, scoreB: 30 }
        return m
      }),
      emptyGroups(),
    )
    const withSemifinalScore = decided.map((m) =>
      m.id === 'sf-1' ? { ...m, scoreA: 30, scoreB: 18 } : m,
    )

    const rescored = withSemifinalScore.map((m) =>
      m.id === 'qf-1' ? { ...m, scoreA: 10, scoreB: 30 } : m,
    )
    const next = propagateBracket(rescored, emptyGroups())

    expect(next.find((m) => m.id === 'sf-1')).toMatchObject({
      pairAId: 'b2',
      scoreA: null,
      scoreB: null,
    })
  })
})