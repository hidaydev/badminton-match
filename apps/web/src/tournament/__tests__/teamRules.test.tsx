import { describe, expect, it } from 'vitest'
import type { TeamInfo, TeamMatch, TeamPartai, TeamSnapshot } from '../types'
import {
  GROUP_DRAW_SLOTS,
  TEAM_CLASSES,
  TEAM_NAMES,
  champion,
  classInPartai,
  computeStandings,
  drawGroupMatches,
  finalMatch,
  partaiClasses,
  targetScore,
  teamMatchPoints,
} from '../team/rules'

function team(index: number): TeamInfo {
  const name = TEAM_NAMES[index - 1]
  return {
    id: `t${index}`,
    name,
    players: TEAM_CLASSES.map((cls) => ({ name: `${name} ${cls}`, cls })),
  }
}

function teams(count = 6): TeamInfo[] {
  return Array.from({ length: count }, (_, index) => team(index + 1))
}

function scored(
  id: string,
  teamA: string,
  teamB: string,
  scores: [number | null, number | null][],
  phase: TeamMatch['phase'] = 'group',
): TeamMatch {
  return {
    id,
    phase,
    teamA,
    teamB,
    partai: scores.map(([scoreA, scoreB]) => ({ scoreA, scoreB })),
    courts: ['Court 12', 'Court 12', 'Court 12'],
  }
}

function snapshot(matches: TeamMatch[]): TeamSnapshot {
  return {
    format: 'team',
    name: 'Friday Night',
    date: '2026-11-06',
    teams: teams(),
    matches,
  }
}

describe('team partai mapping and targets', () => {
  it('maps partai 0/1/2 to C+/C, A+/A and B+/B', () => {
    expect(partaiClasses(0)).toEqual(['C+', 'C'])
    expect(partaiClasses(1)).toEqual(['A+', 'A'])
    expect(partaiClasses(2)).toEqual(['B+', 'B'])
    expect(partaiClasses(3)).toBeNull()

    expect(classInPartai(0, 'C+')).toBe(true)
    expect(classInPartai(0, 'C')).toBe(true)
    expect(classInPartai(0, 'A+')).toBe(false)
    expect(classInPartai(1, 'A')).toBe(true)
    expect(classInPartai(2, 'B')).toBe(true)
  })

  it('uses target 30 in the group and 42 in the final', () => {
    expect(targetScore('group')).toBe(30)
    expect(targetScore('final')).toBe(42)
  })

  it('builds the fixed nine-match draw over the draw slots', () => {
    const ids = ['a', 'b', 'c', 'd', 'e', 'f']
    const matches = drawGroupMatches(ids)

    expect(matches).toHaveLength(9)
    expect(matches.map((match) => match.id)).toEqual([
      'g-1',
      'g-2',
      'g-3',
      'g-4',
      'g-5',
      'g-6',
      'g-7',
      'g-8',
      'g-9',
    ])
    expect(matches.every((match) => match.phase === 'group')).toBe(true)
    expect(matches.every((match) => match.partai.length === 3)).toBe(true)

    const appearances = new Map<string, number>()
    const pairings = new Set<string>()
    for (const match of matches) {
      appearances.set(match.teamA, (appearances.get(match.teamA) ?? 0) + 1)
      appearances.set(match.teamB, (appearances.get(match.teamB) ?? 0) + 1)
      pairings.add([match.teamA, match.teamB].sort().join('|'))
    }
    expect(appearances.size).toBe(6)
    expect([...appearances.values()]).toEqual([3, 3, 3, 3, 3, 3])
    expect(pairings.size).toBe(9)

    GROUP_DRAW_SLOTS.forEach((slot, index) => {
      expect(matches[index].teamA).toBe(ids[slot.teamA])
      expect(matches[index].teamB).toBe(ids[slot.teamB])
      expect(matches[index].courts).toEqual([slot.court, slot.court, slot.court])
    })
  })

  it('puts the final on Court 12 with three unplayed partai', () => {
    const match = finalMatch('t1', 't2')
    expect(match.phase).toBe('final')
    expect(match.id).toBe('final')
    expect(match.partai).toEqual([
      { scoreA: null, scoreB: null },
      { scoreA: null, scoreB: null },
      { scoreA: null, scoreB: null },
    ])
    expect(match.courts).toEqual(['Court 12', 'Court 12', 'Court 12'])
  })
})

describe('team match points', () => {
  it('awards 3/2/1/0 for 3-0, 2-1, 1-2 and 0-3', () => {
    expect(teamMatchPoints(3, 0)).toBe(3)
    expect(teamMatchPoints(2, 1)).toBe(2)
    expect(teamMatchPoints(1, 2)).toBe(1)
    expect(teamMatchPoints(0, 3)).toBe(0)
  })
})

describe('computeStandings', () => {
  it('counts complete team-matches only and orders by points, balance, diff', () => {
    const matches = [
      scored('g-1', 't1', 't2', [
        [30, 10],
        [30, 10],
        [30, 10],
      ]),
      scored('g-2', 't3', 't4', [
        [30, 10],
        [10, 30],
        [30, 20],
      ]),
      scored('g-3', 't5', 't6', [
        [10, 30],
        [20, 30],
        [30, 0],
      ]),
      // One partai still empty: the whole team-match must be ignored.
      scored('g-4', 't1', 't3', [
        [30, 10],
        [null, null],
        [30, 10],
      ]),
    ]

    const standings = computeStandings(teams(), matches)
    expect(standings.map((row) => row.teamId)).toEqual([
      't1',
      't3',
      't6',
      't5',
      't4',
      't2',
    ])

    const red = standings[0]
    expect(red).toMatchObject({
      teamName: 'RED RAPTORS',
      played: 1,
      wins: 3,
      losses: 0,
      points: 3,
      pointsFor: 90,
      pointsAgainst: 30,
    })
  })

  it('uses partai balance before aggregate point difference', () => {
    const matches = [
      // 2 partai won, one tied: 2 points, balance +2, diff +2.
      scored('g-1', 't1', 't2', [
        [10, 10],
        [20, 19],
        [20, 19],
      ]),
      // 2-1: 2 points, balance +1, diff +10.
      scored('g-2', 't3', 't4', [
        [30, 10],
        [10, 30],
        [30, 20],
      ]),
    ]

    const standings = computeStandings(teams(), matches)
    expect(standings.map((row) => row.teamId).slice(0, 2)).toEqual(['t1', 't3'])
    expect(standings[0].points).toBe(standings[1].points)
    expect(standings[0].wins - standings[0].losses).toBe(2)
    expect(standings[1].wins - standings[1].losses).toBe(1)
    // The diff tiebreaker alone would have put t3 first.
    expect(
      standings[1].pointsFor -
        standings[1].pointsAgainst -
        (standings[0].pointsFor - standings[0].pointsAgainst),
    ).toBeGreaterThan(0)
  })

  it('keeps team input order for a full tie', () => {
    const matches = [
      scored('g-1', 't1', 't2', [
        [30, 10],
        [30, 10],
        [30, 10],
      ]),
      scored('g-2', 't3', 't4', [
        [30, 10],
        [30, 10],
        [30, 10],
      ]),
    ]

    const standings = computeStandings(teams(4), matches)
    expect(standings.map((row) => row.teamId)).toEqual(['t1', 't3', 't2', 't4'])
  })
})

describe('champion', () => {
  const finalScores: TeamPartai[] = [
    { scoreA: 42, scoreB: 30 },
    { scoreA: 30, scoreB: 42 },
    { scoreA: 42, scoreB: 40 },
  ]

  it('returns the winner once every partai is scored', () => {
    const decided = snapshot([
      finalMatch('t1', 't2'),
    ])
    decided.matches[0] = { ...decided.matches[0], partai: finalScores }
    expect(champion(decided)).toBe('t1')
  })

  it('returns null while the final is unfinished or missing', () => {
    expect(champion(snapshot([finalMatch('t1', 't2')]))).toBeNull()
    expect(champion(snapshot([]))).toBeNull()
  })
})
