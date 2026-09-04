import test from 'node:test'
import assert from 'node:assert/strict'
import { computeBackToBackRunBySlot } from '../../src/utils/playerStats.ts'
import type { ScheduleSlot } from '../../src/types/index.ts'
import { toPlayerId } from '../../src/types/index.ts'

/** Build a schedule from explicit [slot, [a, b, c, d]] assignments. */
function schedule(entries: [number, string[]][]): ScheduleSlot[] {
  return entries.map(([slot, ids]) => ({
    slot,
    court: 0,
    teamA: [toPlayerId(ids[0]), toPlayerId(ids[1])],
    teamB: [toPlayerId(ids[2]), toPlayerId(ids[3])],
  }))
}

test('3 consecutive slots → every slot in the run gets 3', () => {
  // A plays slots 1-2-3, B plays 1-2, C plays 2-3, D plays 1 and 3 (rest at 2).
  const s = schedule([
    [1, ['A', 'B', 'D', 'E']],
    [2, ['A', 'B', 'C', 'F']],
    [3, ['A', 'C', 'D', 'G']],
  ])
  const runs = computeBackToBackRunBySlot(s, ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'])
  assert.deepEqual([...runs[toPlayerId('A')].entries()], [[1, 3], [2, 3], [3, 3]])
  assert.deepEqual([...runs[toPlayerId('B')].entries()], [[1, 2], [2, 2]])
  assert.deepEqual([...runs[toPlayerId('C')].entries()], [[2, 2], [3, 2]])
  // D plays slot 1 and 3 with a rest at 2 → gap breaks the run, not back-to-back.
  assert.equal(runs[toPlayerId('D')].size, 0)
  // E/F/G/H play a single slot → no entries.
  for (const id of ['E', 'F', 'G', 'H']) assert.equal(runs[toPlayerId(id)].size, 0)
})

test('two separate runs each get their own per-slot marker', () => {
  // A plays 1-2 and 6-7 → slots 1,2 and 6,7 each show 2, nothing summed.
  const s = schedule([
    [1, ['A', 'B', 'C', 'D']],
    [2, ['A', 'E', 'F', 'G']],
    [3, ['H', 'I', 'J', 'K']],
    [4, ['L', 'M', 'N', 'O']],
    [5, ['P', 'Q', 'R', 'S']],
    [6, ['A', 'T', 'U', 'V']],
    [7, ['A', 'W', 'X', 'Y']],
  ])
  const runs = computeBackToBackRunBySlot(s, ['A'])
  assert.deepEqual([...runs[toPlayerId('A')].entries()], [[1, 2], [2, 2], [6, 2], [7, 2]])
})

test('run then a lone later game: only the run slots are marked', () => {
  // A plays 2-3-4 (run of 3) then a single game at 7. Slots 2,3,4 → 3; slot 7 has no entry.
  const s = schedule([
    [1, ['B', 'C', 'D', 'E']],
    [2, ['A', 'B', 'C', 'D']],
    [3, ['A', 'E', 'F', 'G']],
    [4, ['A', 'H', 'I', 'J']],
    [5, ['B', 'C', 'D', 'E']],
    [6, ['B', 'C', 'D', 'E']],
    [7, ['A', 'K', 'L', 'M']],
  ])
  const runs = computeBackToBackRunBySlot(s, ['A'])
  assert.deepEqual([...runs[toPlayerId('A')].entries()], [[2, 3], [3, 3], [4, 3]])
})

test('non-zero slot numbering: slots 2-3-4 are still a consecutive run', () => {
  // Slots are numbered 2, 3, 4 (no slot 1) — consecutive numbering, run of 3.
  const s = schedule([
    [2, ['A', 'B', 'C', 'D']],
    [3, ['A', 'E', 'F', 'G']],
    [4, ['A', 'H', 'I', 'J']],
  ])
  const runs = computeBackToBackRunBySlot(s, ['A', 'B'])
  assert.deepEqual([...runs[toPlayerId('A')].entries()], [[2, 3], [3, 3], [4, 3]])
  assert.equal(runs[toPlayerId('B')].size, 0)
})

test('players with no games get empty maps', () => {
  const s = schedule([[0, ['A', 'B', 'C', 'D']]])
  const runs = computeBackToBackRunBySlot(s, ['A', 'Zed'])
  assert.equal(runs[toPlayerId('A')].size, 0)
  assert.equal(runs[toPlayerId('Zed')].size, 0)
})