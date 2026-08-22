import test from 'node:test'
import assert from 'node:assert/strict'
import { initTallyRow, tallyMatch, computeDiff, standardStandingSort } from '../../src/utils/tally.ts'
import { computeStandings } from '../../src/utils/standings.ts'
import { toPlayerId, toGameKey } from '../../src/types/index.ts'
import type { Player, ScheduleSlot, GameScore, PlayerId } from '../../src/types'

// Aturan W/L/P — MIRROR formula di majadu-api/internal/store/stats.go
// (win = skor tim lebih besar; pointsFor = skor tim sendiri). Jaga konsisten.
test('tallyMatch: menang/seri/kalah + poin', () => {
  const row = initTallyRow()
  tallyMatch(row, 21, 18) // menang
  tallyMatch(row, 19, 21) // kalah
  tallyMatch(row, 21, 20) // menang
  assert.equal(row.wins, 2)
  assert.equal(row.losses, 1)
  assert.equal(row.pointsFor, 21 + 19 + 21)
  assert.equal(row.pointsAgainst, 18 + 21 + 20)
})

test('computeDiff: selisih poin', () => {
  const row = initTallyRow()
  tallyMatch(row, 21, 18)
  computeDiff(row)
  assert.equal(row.diff, 3)
})

test('standardStandingSort: wins → diff → pointsFor', () => {
  const a = { ...initTallyRow(), wins: 2, diff: 5, pointsFor: 42 }
  const b = { ...initTallyRow(), wins: 2, diff: 3, pointsFor: 40 }
  const c = { ...initTallyRow(), wins: 1, diff: 10, pointsFor: 50 }
  const sorted = [c, a, b].sort(standardStandingSort)
  assert.deepEqual(sorted.map((r) => r.wins), [2, 2, 1])
  assert.deepEqual(sorted.slice(0, 2).map((r) => r.diff), [5, 3])
})

// ── Game dengan absent player — semantik skip_player (konsisten rating engine) ──
// Game yang memuat pemain absent TETAP dihitung untuk pemain yang main;
// hanya pemain absent yang di-exclude dari tally. Game di-skip hanya jika
// salah satu tim tidak punya pemain aktif sama sekali.

function makePlayer(id: string): Player {
  return { id: toPlayerId(id), name: id, gender: 'M', tier: 2 }
}

function makeStandingsFixture() {
  const p1 = makePlayer('p1')
  const p2 = makePlayer('p2')
  const p3 = makePlayer('p3')
  const p4 = makePlayer('p4')
  const pAbsent = makePlayer('pAbsent')
  const schedule: ScheduleSlot[] = [
    // game valid: p1+p2 vs p3+p4
    { slot: 1, court: 1, teamA: [toPlayerId('p1'), toPlayerId('p2')], teamB: [toPlayerId('p3'), toPlayerId('p4')] },
    // game dengan pAbsent di tim A: TETAP dihitung untuk p2, p3, p4
    { slot: 2, court: 1, teamA: [toPlayerId('pAbsent'), toPlayerId('p2')], teamB: [toPlayerId('p3'), toPlayerId('p4')] },
    // game dengan pAbsent di tim B: TETAP dihitung untuk p1, p2, p3
    { slot: 3, court: 1, teamA: [toPlayerId('p1'), toPlayerId('p2')], teamB: [toPlayerId('p3'), toPlayerId('pAbsent')] },
  ]
  const gameScores: Record<string, GameScore> = {
    [toGameKey(1, 1)]: { a: 21, b: 15 },
    [toGameKey(2, 1)]: { a: 21, b: 10 },
    [toGameKey(3, 1)]: { a: 12, b: 21 },
  }
  return { players: [p1, p2, p3, p4, pAbsent], schedule, gameScores }
}

test('computeStandings: game dengan absent tetap dihitung untuk pemain yang main (skip_player)', () => {
  const { players, schedule, gameScores } = makeStandingsFixture()
  const voidIds: PlayerId[] = [toPlayerId('pAbsent')]
  const rows = computeStandings(
    players.filter((p) => p.id !== toPlayerId('pAbsent')),
    schedule,
    gameScores,
    voidIds,
  )
  const byId = new Map(rows.map((r) => [r.player.id, r]))

  // Game 1 valid: p1+p2 menang 21-15
  // Game 2 (pAbsent di A): p2 menang 21-10, p3+p4 kalah
  // Game 3 (pAbsent di B): p1+p2 kalah 12-21, p3 menang
  assert.equal(byId.get(toPlayerId('p1'))!.wins, 1)
  assert.equal(byId.get(toPlayerId('p1'))!.losses, 1)
  assert.equal(byId.get(toPlayerId('p1'))!.pointsFor, 21 + 12)
  // p2 main di 3 game → 2 menang 1 kalah (game dengan absent TETAP dihitung)
  assert.equal(byId.get(toPlayerId('p2'))!.wins, 2)
  assert.equal(byId.get(toPlayerId('p2'))!.losses, 1)
  assert.equal(byId.get(toPlayerId('p2'))!.pointsFor, 21 + 21 + 12)
  // p3: kalah game 1 & 2, menang game 3
  assert.equal(byId.get(toPlayerId('p3'))!.wins, 1)
  assert.equal(byId.get(toPlayerId('p3'))!.losses, 2)
  assert.equal(byId.get(toPlayerId('p4'))!.losses, 2)
})

test('computeStandings: tanpa voidPlayerIds tetap menghitung semua game (backward compat)', () => {
  const { players, schedule, gameScores } = makeStandingsFixture()
  const rows = computeStandings(
    players.filter((p) => p.id !== toPlayerId('pAbsent')),
    schedule,
    gameScores,
  )
  const byId = new Map(rows.map((r) => [r.player.id, r]))
  // p2 ikut di 3 game → 2 menang 1 kalah
  assert.equal(byId.get(toPlayerId('p2'))!.wins, 2)
  assert.equal(byId.get(toPlayerId('p2'))!.losses, 1)
})

test('computeStandings: tim tanpa pemain aktif sama sekali → game di-skip', () => {
  const p1 = makePlayer('p1')
  const p2 = makePlayer('p2')
  const p3 = makePlayer('p3')
  const schedule: ScheduleSlot[] = [
    // tim A = 2 pemain absent semua → game tidak valid
    { slot: 1, court: 1, teamA: [toPlayerId('pAbsent1'), toPlayerId('pAbsent2')], teamB: [toPlayerId('p1'), toPlayerId('p2')] },
    { slot: 2, court: 1, teamA: [toPlayerId('p1'), toPlayerId('p2')], teamB: [toPlayerId('p3'), toPlayerId('pAbsent1')] },
  ]
  const gameScores: Record<string, GameScore> = {
    [toGameKey(1, 1)]: { a: 21, b: 10 },
    [toGameKey(2, 1)]: { a: 12, b: 21 },
  }
  const rows = computeStandings(
    [p1, p2, p3],
    schedule,
    gameScores,
    [toPlayerId('pAbsent1'), toPlayerId('pAbsent2')],
  )
  const byId = new Map(rows.map((r) => [r.player.id, r]))
  // Game 1 skip (tim A kosong); game 2: p3 menang 21-12
  assert.equal(byId.get(toPlayerId('p1'))!.wins, 0)
  assert.equal(byId.get(toPlayerId('p1'))!.losses, 1)
  assert.equal(byId.get(toPlayerId('p3'))!.wins, 1)
})
