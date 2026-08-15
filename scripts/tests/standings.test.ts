import test from 'node:test'
import assert from 'node:assert/strict'
import { initTallyRow, tallyMatch, computeDiff, standardStandingSort } from '../../src/utils/tally.ts'

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
