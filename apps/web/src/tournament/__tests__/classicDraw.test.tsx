import { describe, expect, it } from 'vitest'
import {
  GROUP_IDS,
  computeGroupStandings,
  drawGroups,
  generateTournament,
  propagateBracket,
} from '../classic/draw'
import type { ClassicMatch, ClassicSnapshot, Pair } from '../types'

function pairs(): Pair[] {
  return Array.from({ length: 16 }, (_, index) => ({
    id: `p${index + 1}`,
    name: `Pair ${index + 1}`,
  }))
}

/** Six round-robin rows for group A, in slot order, with no scores. */
function groupAMatches(): ClassicMatch[] {
  const slots: [string, string][] = [
    ['a', 'b'],
    ['c', 'd'],
    ['a', 'c'],
    ['b', 'd'],
    ['a', 'd'],
    ['b', 'c'],
  ]
  return slots.map(([pairAId, pairBId], index) => ({
    id: `group-A-${index}`,
    phase: 'group' as const,
    groupId: 'A' as const,
    pairAId,
    pairBId,
    scoreA: null,
    scoreB: null,
  }))
}

function scored(
  matches: ClassicMatch[],
  scores: Record<string, [number, number]>,
): ClassicMatch[] {
  return matches.map((match) => {
    const result = scores[match.id]
    return result === undefined ? match : { ...match, scoreA: result[0], scoreB: result[1] }
  })
}

function withScore(
  snapshot: ClassicSnapshot,
  id: string,
  scoreA: number,
  scoreB: number,
): ClassicSnapshot {
  const matches = scored(snapshot.matches, { [id]: [scoreA, scoreB] })
  return { ...snapshot, matches: propagateBracket(matches, snapshot.groups) }
}

describe('classic draw', () => {
  it('deals sixteen unique pairs into four groups of four', () => {
    const ids = pairs().map((pair) => pair.id)
    const groups = drawGroups(ids, 42)
    const dealt = GROUP_IDS.flatMap((groupId) => groups[groupId])

    expect(dealt).toHaveLength(16)
    expect(new Set(dealt).size).toBe(16)
    for (const groupId of GROUP_IDS) {
      expect(groups[groupId]).toHaveLength(4)
    }
  })

  it('generates 24 group matches and the eight v1 knockout rows', () => {
    const snapshot = generateTournament('Cup', '2026-11-04', pairs(), 42)

    expect(snapshot.matches).toHaveLength(32)
    const groupRows = snapshot.matches.filter((match) => match.phase === 'group')
    expect(groupRows).toHaveLength(24)
    expect(groupRows[0].id).toBe('group-A-0')
    expect(groupRows[23].id).toBe('group-D-5')
    expect(snapshot.matches.filter((match) => match.phase !== 'group').map((match) => match.id)).toEqual([
      'qf-1',
      'qf-2',
      'qf-3',
      'qf-4',
      'sf-1',
      'sf-2',
      '3rd-1',
      'final-1',
    ])
  })

  it('seeds the quarterfinals A1-B2, C2-D1, C1-D2, A2-B1', () => {
    const snapshot = generateTournament('Cup', '2026-11-04', pairs(), 42)
    const { A, B, C, D } = snapshot.groups
    const byId = new Map(snapshot.matches.map((match) => [match.id, match]))

    expect([byId.get('qf-1')?.pairAId, byId.get('qf-1')?.pairBId]).toEqual([A[0], B[1]])
    expect([byId.get('qf-2')?.pairAId, byId.get('qf-2')?.pairBId]).toEqual([C[1], D[0]])
    expect([byId.get('qf-3')?.pairAId, byId.get('qf-3')?.pairBId]).toEqual([C[0], D[1]])
    expect([byId.get('qf-4')?.pairAId, byId.get('qf-4')?.pairBId]).toEqual([A[1], B[0]])
  })

  it('rebuilds the same draw from the same seed', () => {
    const ids = pairs().map((pair) => pair.id)
    expect(drawGroups(ids, 7)).toEqual(drawGroups(ids, 7))
    expect(drawGroups(ids, 8)).not.toEqual(drawGroups(ids, 7))
  })
})

describe('classic standings', () => {
  it('orders by wins, then difference, then points for', () => {
    const matches = scored(groupAMatches(), {
      'group-A-0': [21, 19],
      'group-A-2': [21, 10],
      'group-A-4': [15, 21],
      'group-A-5': [19, 14],
      'group-A-3': [19, 15],
    })

    const rows = computeGroupStandings('A', ['a', 'b', 'c', 'd'], matches)

    expect(rows.map((row) => row.pairId)).toEqual(['a', 'b', 'd', 'c'])
    expect(rows[0]).toMatchObject({ wins: 2, losses: 1, pointsFor: 57, diff: 7 })
    expect(rows[1]).toMatchObject({ wins: 2, losses: 1, pointsFor: 57, diff: 7 })
  })

  it('breaks a full tie by the first head-to-head meeting', () => {
    const matches = scored(groupAMatches(), {
      'group-A-0': [19, 21],
      'group-A-2': [21, 10],
      'group-A-4': [21, 14],
      'group-A-5': [21, 5],
      'group-A-3': [19, 21],
    })

    const rows = computeGroupStandings('A', ['a', 'b', 'c', 'd'], matches)

    expect(rows.map((row) => row.pairId)).toEqual(['b', 'a', 'd', 'c'])
    expect(rows[0]).toMatchObject({ wins: 2, losses: 1, pointsFor: 61, diff: 16 })
    expect(rows[1]).toMatchObject({ wins: 2, losses: 1, pointsFor: 61, diff: 16 })
  })
})

describe('classic bracket propagation', () => {
  it('fills a semifinal slot from the quarterfinal winner and leaves the other side to be decided', () => {
    const snapshot = generateTournament('Cup', '2026-11-04', pairs(), 42)
    const quarterfinal = snapshot.matches.find((match) => match.id === 'qf-1')!
    const advanced = withScore(snapshot, 'qf-1', 21, 10)
    const semifinal = advanced.matches.find((match) => match.id === 'sf-1')!

    expect(semifinal.pairAId).toBe(quarterfinal.pairAId)
    expect(semifinal.pairBId).toBeNull()
  })

  it('clears a downstream score when a feeder pairing changes', () => {
    let snapshot = generateTournament('Cup', '2026-11-04', pairs(), 42)
    for (const [id, scoreB] of [
      ['qf-1', 10],
      ['qf-2', 11],
      ['qf-3', 12],
      ['qf-4', 13],
    ] as const) {
      snapshot = withScore(snapshot, id, 21, scoreB)
    }
    snapshot = withScore(snapshot, 'sf-1', 21, 14)
    snapshot = withScore(snapshot, 'sf-2', 21, 15)
    snapshot = withScore(snapshot, 'final-1', 21, 16)

    const before = snapshot.matches.find((match) => match.id === 'sf-1')!
    expect(before.pairAId).not.toBeNull()
    expect(before.scoreA).toBe(21)

    const tampered = snapshot.matches.map((match) =>
      match.id === 'qf-1' ? { ...match, pairAId: 'tampered-pair' } : match,
    )
    const after = propagateBracket(tampered, snapshot.groups)

    const quarterfinal = after.find((match) => match.id === 'qf-1')!
    const semifinal = after.find((match) => match.id === 'sf-1')!
    const final = after.find((match) => match.id === 'final-1')!

    // The regrouped slot no longer matches the standings, so the domain clears
    // its score; the loser of that decision empties the semifinal and final.
    expect(quarterfinal.scoreA).toBeNull()
    expect(semifinal.pairAId).toBeNull()
    expect(semifinal.scoreA).toBeNull()
    expect(final.scoreA).toBeNull()
  })
})
