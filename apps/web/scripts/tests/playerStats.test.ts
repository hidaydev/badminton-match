import test from 'node:test'
import assert from 'node:assert/strict'
import { computeBackToBackRuns } from '../../src/utils/playerStats.ts'
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

test('3 consecutive slots → [3] (games played without rest)', () => {
  // A plays slots 1-2-3, B plays 1-2, C plays 2-3, D plays 1 and 3 (rest at 2).
  const s = schedule([
    ['A', 'B', 'D', 'E'],
    ['A', 'B', 'C', 'F'],
    ['A', 'C', 'D', 'G'],
  ])
  const runs = computeBackToBackRuns(s, ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'])
  assert.deepEqual(runs[toPlayerId('A')], [3])
  assert.deepEqual(runs[toPlayerId('B')], [2])
  assert.deepEqual(runs[toPlayerId('C')], [2])
  // D plays slot 1 and 3 with a rest at 2 → gap breaks the run, not back-to-back.
  assert.deepEqual(runs[toPlayerId('D')], [])
  // E/F/G/H play a single slot → [].
  assert.deepEqual(runs[toPlayerId('E')], [])
  assert.deepEqual(runs[toPlayerId('F')], [])
  assert.deepEqual(runs[toPlayerId('G')], [])
  assert.deepEqual(runs[toPlayerId('H')], [])
})

test('two separate runs are reported separately, not summed', () => {
  // A plays 1-2 and 4-5-6 → [2, 3], rendered as "*2 *3".
  const s = schedule([
    ['A', 'B', 'C', 'D'],
    ['A', 'E', 'F', 'G'],
    ['H', 'I', 'J', 'K'],
    ['A', 'L', 'M', 'N'],
    ['A', 'O', 'P', 'Q'],
    ['A', 'R', 'S', 'T'],
  ])
  const runs = computeBackToBackRuns(s, ['A'])
  assert.deepEqual(runs[toPlayerId('A')], [2, 3])
})

test('non-zero slot numbering: slots 2-3-4 are still a consecutive run', () => {
  // Slots are numbered 2, 3, 4 (no slot 1) — consecutive numbering, run of 3.
  const s = schedule([
    ['A', 'B', 'C', 'D'],
    ['A', 'E', 'F', 'G'],
    ['A', 'H', 'I', 'J'],
  ]).map((g) => ({ ...g, slot: g.slot + 2 }))
  const runs = computeBackToBackRuns(s, ['A', 'B'])
  assert.deepEqual(runs[toPlayerId('A')], [3])
  assert.deepEqual(runs[toPlayerId('B')], [])
})

test('players with no games get []', () => {
  const s = schedule([['A', 'B', 'C', 'D']])
  const runs = computeBackToBackRuns(s, ['A', 'Zed'])
  assert.deepEqual(runs[toPlayerId('A')], [])
  assert.deepEqual(runs[toPlayerId('Zed')], [])
})