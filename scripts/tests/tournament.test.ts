import test from 'node:test'
import assert from 'node:assert/strict'
import {
  computeGroupStandings,
  generateGroupMatches,
  initKnockoutMatches,
  propagateBracket,
  type GroupId,
  type TournamentMatch,
} from '../../src/utils/tournament.ts'

function scoreGroupMatches(groupId: GroupId, winners: number[]): TournamentMatch[] {
  return generateGroupMatches(groupId, [`${groupId}1`, `${groupId}2`, `${groupId}3`, `${groupId}4`]).map((match, index) => {
    const pairAWin = winners.includes(index)
    return {
      ...match,
      scoreA: pairAWin ? 30 : 21,
      scoreB: pairAWin ? 21 : 30,
    }
  })
}

test('computeGroupStandings orders rows by wins then point diff', () => {
  const pairIds = ['A1', 'A2', 'A3', 'A4']
  const matches = scoreGroupMatches('A', [0, 2, 4, 5])
  const standings = computeGroupStandings('A', pairIds, matches)

  assert.deepEqual(
    standings.map((row) => row.pairId),
    ['A1', 'A4', 'A2', 'A3'],
  )
  assert.equal(standings[0].wins, 3)
  assert.equal(standings[3].wins, 0)
})

test('propagateBracket seeds quarterfinals and advances winners through final', () => {
  const groups = {
    A: ['A1', 'A2', 'A3', 'A4'],
    B: ['B1', 'B2', 'B3', 'B4'],
    C: ['C1', 'C2', 'C3', 'C4'],
    D: ['D1', 'D2', 'D3', 'D4'],
  }

  const groupMatches = [
    ...scoreGroupMatches('A', [0, 2, 4, 5]),
    ...scoreGroupMatches('B', [0, 2, 4, 5]),
    ...scoreGroupMatches('C', [0, 2, 4, 5]),
    ...scoreGroupMatches('D', [0, 2, 4, 5]),
  ]

  let matches = [...groupMatches, ...initKnockoutMatches()]
  matches = propagateBracket(matches, groups)

  assert.deepEqual(
    matches
      .filter((match) => match.phase === 'qf')
      .map((match) => [match.id, match.pairAId, match.pairBId]),
    [
      ['qf-1', 'A1', 'B4'],
      ['qf-2', 'C4', 'D1'],
      ['qf-3', 'C1', 'D4'],
      ['qf-4', 'A4', 'B1'],
    ],
  )

  const scoredQf = matches.map((match) => {
    if (match.id === 'qf-1') return { ...match, scoreA: 30, scoreB: 18 }
    if (match.id === 'qf-2') return { ...match, scoreA: 17, scoreB: 30 }
    if (match.id === 'qf-3') return { ...match, scoreA: 30, scoreB: 25 }
    if (match.id === 'qf-4') return { ...match, scoreA: 30, scoreB: 27 }
    return match
  })

  const scoredSf = propagateBracket(scoredQf, groups).map((match) => {
    if (match.id === 'sf-1') return { ...match, scoreA: 30, scoreB: 24 }
    if (match.id === 'sf-2') return { ...match, scoreA: 22, scoreB: 30 }
    return match
  })

  const finalState = propagateBracket(scoredSf, groups)
  const final = finalState.find((match) => match.id === 'final-1')
  const third = finalState.find((match) => match.id === '3rd-1')

  assert.deepEqual(
    [final?.pairAId, final?.pairBId],
    ['A1', 'A4'],
  )
  assert.deepEqual(
    [third?.pairAId, third?.pairBId],
    ['D1', 'C1'],
  )
})
