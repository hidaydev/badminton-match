import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { generateTeamDraw, teamTarget, PARTAI_CLASSES } from '../../src/utils/teamTournament.ts'

// Golden fixture lintas-bahasa — dipakai juga oleh test Go
// (apps/api/internal/domain/team_tournament_test.go). Mencegah aturan
// urutan kelas / target / jadwal menyimpang antara frontend dan backend.
interface Golden {
  partaiClasses: [string, string][]
  targets: { group: number; final: number }
  draw: { teamA: number; teamB: number; court: string }[]
}

const golden: Golden = JSON.parse(
  readFileSync(fileURLToPath(new URL('./fixtures/team-tournament.golden.json', import.meta.url)), 'utf8'),
)

test('golden: PARTAI_CLASSES & teamTarget selaras fixture bersama', () => {
  assert.deepEqual(PARTAI_CLASSES, golden.partaiClasses)
  assert.equal(teamTarget('group'), golden.targets.group)
  assert.equal(teamTarget('final'), golden.targets.final)
})

test('golden: generateTeamDraw selaras fixture bersama', () => {
  const ids = ['t1', 't2', 't3', 't4', 't5', 't6']
  const draw = generateTeamDraw(ids)
  const asIndices = draw.map(([a, b, court]) => ({ teamA: ids.indexOf(a), teamB: ids.indexOf(b), court }))
  assert.deepEqual(asIndices, golden.draw)
})
