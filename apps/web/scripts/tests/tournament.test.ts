import test from 'node:test'
import assert from 'node:assert/strict'
import {
  generateGroupMatches,
  initKnockoutMatches,
  computeGroupStandings,
  propagateBracket,
  type TournamentMatch,
  type GroupId,
} from '../../src/utils/tournament.ts'

const GROUP_IDS: GroupId[] = ['A', 'B', 'C', 'D']

function groupPairs(prefix: string): string[] {
  return [`${prefix}1`, `${prefix}2`, `${prefix}3`, `${prefix}4`]
}

function groupsWithAllPairs(): Record<GroupId, string[]> {
  return {
    A: groupPairs('a'),
    B: groupPairs('b'),
    C: groupPairs('c'),
    D: groupPairs('d'),
  }
}

test('generateGroupMatches: round-robin 4 pasangan = 6 match', () => {
  const matches = generateGroupMatches('A', groupPairs('a'))
  assert.equal(matches.length, 6)
  assert.ok(matches.every((m) => m.phase === 'group' && m.groupId === 'A'))
  assert.ok(matches.every((m) => m.pairAId && m.pairBId))
  assert.equal(new Set(matches.map((m) => m.id)).size, 6)
})

test('initKnockoutMatches: 4 QF + 2 SF + 3rd + final', () => {
  const ko = initKnockoutMatches()
  assert.equal(ko.filter((m) => m.phase === 'qf').length, 4)
  assert.equal(ko.filter((m) => m.phase === 'sf').length, 2)
  assert.equal(ko.filter((m) => m.phase === '3rd').length, 1)
  assert.equal(ko.filter((m) => m.phase === 'final').length, 1)
  assert.ok(ko.every((m) => m.pairAId === null && m.pairBId === null))
})

test('computeGroupStandings: urutkan menang lalu selisih poin', () => {
  // a1 menang 2, a2 menang 1, a3 menang 1 (selisih lebih kecil), a4 0
  const matches = generateGroupMatches('A', groupPairs('a'))
  const set = (id: string, a: number, b: number) => {
    const m = matches.find((x) => x.id === id)!
    m.scoreA = a
    m.scoreB = b
  }
  set('group-A-0', 21, 10) // a1 vs a2 → a1
  set('group-A-1', 21, 15) // a3 vs a4 → a3
  set('group-A-2', 21, 12) // a1 vs a3 → a1
  set('group-A-3', 21, 18) // a2 vs a4 → a2
  set('group-A-4', 21, 8)  // a1 vs a4 → a1
  set('group-A-5', 19, 21) // a2 vs a3 → a3

  const rows = computeGroupStandings('A', groupPairs('a'), matches)
  assert.equal(rows[0].pairId, 'a1') // 3 menang
  assert.equal(rows[1].pairId, 'a3') // 2 menang (selisih lebih besar dari a2)
  assert.equal(rows[2].pairId, 'a2') // 1 menang
  assert.equal(rows[3].pairId, 'a4') // 0 menang
})

test('propagateBracket: seed QF dan propagate juara ke final', () => {
  const groups = groupsWithAllPairs()
  let matches: TournamentMatch[] = [
    ...GROUP_IDS.flatMap((g) => generateGroupMatches(g, groups[g])),
    ...initKnockoutMatches(),
  ]

  const setScore = (m: TournamentMatch, a: number, b: number) => {
    m.scoreA = a
    m.scoreB = b
  }

  // Skor grup: urutan juara = 1 > 2 > 3 > 4 di tiap grup
  for (const g of GROUP_IDS) {
    const gm = matches.filter((m) => m.phase === 'group' && m.groupId === g)
    setScore(gm[0], 21, 10) // idx0 vs idx1 → idx0
    setScore(gm[1], 21, 12) // idx2 vs idx3 → idx2
    setScore(gm[2], 21, 8)  // idx0 vs idx2 → idx0
    setScore(gm[3], 21, 14) // idx1 vs idx3 → idx1
    setScore(gm[4], 21, 5)  // idx0 vs idx3 → idx0
    setScore(gm[5], 21, 16) // idx1 vs idx2 → idx2
  }
  // Standings: 1 = idx0 (3W), 2 = idx2 (2W), 3 = idx1 (1W), 4 = idx3 (0W)

  matches = propagateBracket(matches, groups)

  // qf-1 = A1 vs B2
  const qf1 = matches.find((m) => m.id === 'qf-1')!
  assert.equal(qf1.pairAId, 'a1')
  assert.equal(qf1.pairBId, 'b2')

  // Skor QF: pemenang seed (a1, c1, d1, b1) menang
  for (const [id, winner] of [['qf-1', 'a1'], ['qf-2', 'd1'], ['qf-3', 'c1'], ['qf-4', 'b1']] as const) {
    const qf = matches.find((m) => m.id === id)!
    setScore(qf, qf.pairAId === winner ? 21 : 10, qf.pairAId === winner ? 10 : 21)
  }
  matches = propagateBracket(matches, groups)

  // sf-1 = winner(qf-1) vs winner(qf-2); sf-2 = winner(qf-3) vs winner(qf-4)
  const sf1 = matches.find((m) => m.id === 'sf-1')!
  assert.equal(sf1.pairAId, 'a1')
  assert.equal(sf1.pairBId, 'd1')
  const sf2 = matches.find((m) => m.id === 'sf-2')!
  assert.equal(sf2.pairAId, 'c1')
  assert.equal(sf2.pairBId, 'b1')

  // SF: a1 dan c1 menang
  setScore(sf1, 21, 9)
  setScore(sf2, 21, 11)
  matches = propagateBracket(matches, groups)

  const final = matches.find((m) => m.id === 'final-1')!
  assert.equal(final.pairAId, 'a1')
  assert.equal(final.pairBId, 'c1')

  const third = matches.find((m) => m.id === '3rd-1')!
  assert.equal(third.pairAId, 'd1')
  assert.equal(third.pairBId, 'b1')
})

test('propagateBracket: aman saat grup belum penuh (null seed)', () => {
  const groups: Record<GroupId, string[]> = { A: ['a1', 'a2'], B: [], C: [], D: [] }
  const matches = propagateBracket([...initKnockoutMatches()], groups)
  const qf1 = matches.find((m) => m.id === 'qf-1')!
  assert.equal(qf1.pairAId, 'a1')
  assert.equal(qf1.pairBId, null)
})
