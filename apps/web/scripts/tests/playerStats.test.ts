import test from 'node:test'
import assert from 'node:assert/strict'
import { computeBackToBackCounts } from '../../src/utils/playerStats.ts'
import type { ScheduleSlot } from '../../src/types/index.ts'
import { toPlayerId } from '../../src/types/index.ts'

/** Build a schedule with the given per-slot player assignments (4 players per slot). */
function schedule(perSlot: string[][]): ScheduleSlot[] {
  const out: ScheduleSlot[] = []
  perSlot.forEach((ids, slot) => {
    out.push({
      slot,
      court: 0,
      teamA: [toPlayerId(ids[0]), toPlayerId(ids[1])],
      teamB: [toPlayerId(ids[2]), toPlayerId(ids[3])],
    })
  })
  return out
}

test('3 consecutive slots → 3 (games played without rest)', () => {
  // A plays slots 1-2-3, B plays 1-2, C plays 2-3, D plays 1 and 3 (rest at 2).
  const s = schedule([
    ['A', 'B', 'D', 'E'],
    ['A', 'B', 'C', 'F'],
    ['A', 'C', 'D', 'G'],
  ])
  const counts = computeBackToBackCounts(s, ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'])
  assert.equal(counts[toPlayerId('A')], 3)
  assert.equal(counts[toPlayerId('B')], 2)
  assert.equal(counts[toPlayerId('C')], 2)
  // D plays slot 1 and 3 with a rest at 2 → gap breaks the run, not back-to-back.
  assert.equal(counts[toPlayerId('D')], 0)
  // E/F/G/H play a single slot → 0.
  assert.equal(counts[toPlayerId('E')], 0)
  assert.equal(counts[toPlayerId('F')], 0)
  assert.equal(counts[toPlayerId('G')], 0)
  assert.equal(counts[toPlayerId('H')], 0)
})

test('two separate runs sum up', () => {
  // A plays 1-2 and 4-5-6 → 2 + 3 = 5.
  const s = schedule([
    ['A', 'B', 'C', 'D'],
    ['A', 'E', 'F', 'G'],
    ['H', 'I', 'J', 'K'],
    ['A', 'L', 'M', 'N'],
    ['A', 'O', 'P', 'Q'],
    ['A', 'R', 'S', 'T'],
  ])
  const counts = computeBackToBackCounts(s, ['A'])
  assert.equal(counts[toPlayerId('A')], 5)
})

test('non-zero slot numbering: slots 2-3-4 are still a consecutive run', () => {
  // Slots are numbered 2, 3, 4 (no slot 1) — consecutive numbering, run of 3.
  const s = schedule([
    ['A', 'B', 'C', 'D'],
    ['A', 'E', 'F', 'G'],
    ['A', 'H', 'I', 'J'],
  ]).map((g) => ({ ...g, slot: g.slot + 2 }))
  const counts = computeBackToBackCounts(s, ['A', 'B'])
  assert.equal(counts[toPlayerId('A')], 3)
  assert.equal(counts[toPlayerId('B')], 0)
})

test('players with no games get 0', () => {
  const s = schedule([['A', 'B', 'C', 'D']])
  const counts = computeBackToBackCounts(s, ['A', 'Zed'])
  assert.equal(counts[toPlayerId('A')], 0)
  assert.equal(counts[toPlayerId('Zed')], 0)
})