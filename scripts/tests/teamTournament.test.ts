import test from 'node:test'
import assert from 'node:assert/strict'
import {
  computeTeamStandings,
  generateTeamDraw,
  teamMatchOutcome,
  teamMatchPoints,
  teamTarget,
  type TeamInfo,
  type TeamMatch,
} from '../../src/utils/teamTournament.ts'

const CLASSES = ['A+', 'A', 'B+', 'B', 'C+', 'C']

function mkTeams(): TeamInfo[] {
  return Array.from({ length: 6 }, (_, i) => ({
    id: `t${i + 1}`,
    name: `Tim ${i + 1}`,
    players: CLASSES.map((cls) => ({ name: `T${i + 1}-${cls}`, cls: cls as TeamInfo['players'][number]['cls'] })),
  }))
}

function partai(a: number | null, b: number | null) {
  return { scoreA: a, scoreB: b }
}

function mkMatch(id: string, a: string, b: string, scores: (number | null)[][], phase: 'group' | 'final' = 'group'): TeamMatch {
  return {
    id,
    phase,
    teamA: a,
    teamB: b,
    partai: scores.map(([sa, sb]) => partai(sa, sb)),
    courts: ['Court 1', 'Court 2', 'Court 3'],
  }
}

test('teamTarget: grup 30, final 42', () => {
  assert.equal(teamTarget('group'), 30)
  assert.equal(teamTarget('final'), 42)
})

test('teamMatchPoints: 3-0=3 · 2-1=2 · 1-2=1 · 0-3=0', () => {
  assert.equal(teamMatchPoints(3, 0), 3)
  assert.equal(teamMatchPoints(2, 1), 2)
  assert.equal(teamMatchPoints(1, 2), 1)
  assert.equal(teamMatchPoints(0, 3), 0)
})

test('generateTeamDraw: 9 match, tiap tim tepat 3×, tanpa ulangan lawan', () => {
  const ids = ['t1', 't2', 't3', 't4', 't5', 't6']
  for (let run = 0; run < 20; run++) {
    const draw = generateTeamDraw(ids)
    assert.equal(draw.length, 9)
    const appear: Record<string, number> = {}
    const seen = new Set<string>()
    for (const [a, b] of draw) {
      appear[a] = (appear[a] ?? 0) + 1
      appear[b] = (appear[b] ?? 0) + 1
      assert.notEqual(a, b, 'tidak boleh melawan diri sendiri')
      const key = [a, b].sort().join('|')
      assert.ok(!seen.has(key), 'tidak boleh ada duplikat lawan')
      seen.add(key)
    }
    for (const id of ids) {
      assert.equal(appear[id], 3, `${id} harus main 3×`)
    }
  }
})

test('computeTeamStandings: urut poin → selisih W-L → selisih poin', () => {
  const teams = mkTeams()
  // t1: 3 menang 3-0 (9 poin) — juara
  // t2: 3 menang 2-1 (6 poin) — di atas t3 (2-1 + 3-0? buat tie poin)
  // t3: menang 3-0, 3-0, 3-0 = 9 poin? bikin tie dengan t1: t3 9 poin, selisih lebih kecil
  const matches = [
    // t1: 3× 3-0 → 9pt, W-L diff +9
    mkMatch('m1', 't1', 't2', [[30, 20], [30, 15], [30, 10]]),
    mkMatch('m2', 't1', 't3', [[30, 20], [30, 20], [30, 20]]),
    mkMatch('m3', 't1', 't4', [[30, 22], [30, 22], [30, 22]]),
    // t3: 3× 3-0 → 9pt, W-L diff +9, agregat lebih kecil dari t1
    mkMatch('m4', 't3', 't5', [[30, 28], [30, 28], [30, 28]]),
    mkMatch('m5', 't3', 't6', [[30, 29], [30, 29], [30, 29]]),
    // t3 butuh 3 match: m2 dihitung t1-t3 (t3 kalah). jadi t3 cuma 2 menang di atas.
    // tambah t3 vs t2
    mkMatch('m6', 't3', 't2', [[30, 25], [30, 25], [30, 25]]),
    // sisa tim: isi lawan agar masing 3×
    mkMatch('m7', 't2', 't4', [[21, 30], [30, 22], [30, 20]]),
    mkMatch('m8', 't2', 't5', [[30, 18], [30, 18], [30, 18]]),
    mkMatch('m9', 't4', 't6', [[30, 24], [30, 24], [30, 24]]),
    mkMatch('m10', 't4', 't5', [[24, 30], [30, 26], [26, 30]]),
    mkMatch('m11', 't5', 't6', [[30, 19], [30, 19], [30, 19]]),
    mkMatch('m12', 't2', 't6', [[30, 21], [30, 21], [30, 21]]),
    // t4 butuh 3× (m3, m7, m9, m10 = 4?) — jangan pedulikan kelengkapan, fokus urutan.
  ]
  const rows = computeTeamStandings(teams, matches)
  const byId = Object.fromEntries(rows.map((r) => [r.teamId, r]))

  // t1: 9pt (3×3-0)
  assert.equal(byId['t1'].points, 9)
  // t3: m2 kalah dari t1 (0-3 → 0pt), m4/m5/m6 menang 3-0 → 9pt
  assert.equal(byId['t3'].points, 9)
  // t1 vs t3 sama 9pt — selisih W-L: t1 9-0 (+9), t3 9-3 (+6) → t1 juara
  assert.equal(rows[0].teamId, 't1', 't1 juara (poin tie, W-L diff lebih besar)')
  assert.equal(rows[1].teamId, 't3', 't3 runner-up')

  // pastikan sorting tidak crash saat match belum lengkap
  const partial = mkMatch('p1', 't1', 't2', [[30, 20], [], []])
  const partialRows = computeTeamStandings(teams, [partial])
  assert.equal(partialRows[0].played, 0, 'match belum lengkap tidak dihitung')
})

test('teamMatchOutcome: complete & hasil 2-1', () => {
  const m = mkMatch('x', 't1', 't2', [[30, 28], [29, 30], [30, 25]])
  const out = teamMatchOutcome(m)
  assert.equal(out.complete, true)
  assert.equal(out.aWins, 2)
  assert.equal(out.bWins, 1)
})

test('teamMatchOutcome: belum lengkap (ada partai kosong)', () => {
  const m = mkMatch('y', 't1', 't2', [[30, 28], [], []])
  assert.equal(teamMatchOutcome(m).complete, false)
})
