import test from 'node:test'
import assert from 'node:assert/strict'
import {
  computeQuality,
  isGoodQuality,
  type QualityMetrics,
} from '../../src/utils/quality.ts'
import type { GeneratorResult } from '../../src/generator/index.ts'
import type { Player, ScheduleSlot } from '../../src/types/index.ts'
import { toPlayerId } from '../../src/types/index.ts'

/** Build a player map with `count` players, all tier 2. */
function playerMap(count: number): Map<string, Player> {
  const map = new Map<string, Player>()
  for (let i = 1; i <= count; i++) {
    map.set(toPlayerId(`p${i}`), { id: toPlayerId(`p${i}`), name: `P${i}`, gender: 'M', tier: 2 })
  }
  return map
}

/** Fill `slots` with `courts` courts per slot, each court using 4 players from `ids` (rotating by `stride` per slot). */
function rotationSchedule(ids: string[], slots: number, courts: number, stride: number): ScheduleSlot[] {
  const schedule: ScheduleSlot[] = []
  for (let s = 0; s < slots; s++) {
    for (let c = 0; c < courts; c++) {
      const base = (s * stride + c * 4) % ids.length
      const pick = (n: number) => ids[(base + n) % ids.length]
      schedule.push({
        slot: s,
        court: c,
        teamA: [toPlayerId(pick(0)), toPlayerId(pick(1))],
        teamB: [toPlayerId(pick(2)), toPlayerId(pick(3))],
      })
    }
  }
  return schedule
}

function makeResult(schedule: ScheduleSlot[]): GeneratorResult {
  return {
    schedule,
    playCount: {},
    sitCount: {},
    partnerWith: {},
    facedBy: {},
    unplacedFixMatches: [],
  }
}

function qualityFor(ids: string[], schedule: ScheduleSlot[]): QualityMetrics {
  const q = computeQuality(makeResult(schedule), playerMap(ids.length), [])
  assert.ok(q, 'computeQuality should return metrics')
  return q
}

test('8P-2C: back-to-back is mathematically forced (40 = floor)', () => {
  const ids = Array.from({ length: 8 }, (_, i) => `p${i + 1}`)
  // Everyone plays every slot across 2 courts → 40 b2b, floor is also 40.
  const q = qualityFor(ids, rotationSchedule(ids, 6, 2, 0))
  assert.equal(q.backToBackCount, 40)
  assert.equal(q.backToBackFloor, 40)
})

test('12P-2C: floor is 20 (4 forced overlaps × 5 transitions)', () => {
  const ids = Array.from({ length: 12 }, (_, i) => `p${i + 1}`)
  // Slot i uses p(4i+1..4i+8) → 4-player overlap between consecutive slots.
  const q = qualityFor(ids, rotationSchedule(ids, 6, 2, 4))
  assert.equal(q.backToBackFloor, 20)
  assert.equal(q.backToBackCount, 20)
})

test('16P-2C: floor is 0 when players outnumber slot capacity', () => {
  const ids = Array.from({ length: 16 }, (_, i) => `p${i + 1}`)
  // 8 players per slot; stride 8 → consecutive slots share no players.
  const q = qualityFor(ids, rotationSchedule(ids, 6, 2, 8))
  assert.equal(q.backToBackFloor, 0)
  assert.equal(q.backToBackCount, 0)
})

test('16P-3C: floor is 40 when courts outnumber available players', () => {
  const ids = Array.from({ length: 16 }, (_, i) => `p${i + 1}`)
  const q = qualityFor(ids, rotationSchedule(ids, 6, 3, 0))
  assert.equal(q.backToBackFloor, 40)
})

test('isGoodQuality ignores forced back-to-back (config-limited, not a generator failure)', () => {
  const ids = Array.from({ length: 8 }, (_, i) => `p${i + 1}`)
  const schedule = rotationSchedule(ids, 6, 2, 0)
  const q = qualityFor(ids, schedule)
  assert.equal(q.backToBackCount, q.backToBackFloor)
  assert.equal(isGoodQuality(makeResult(schedule), playerMap(8), []), true)
})

test('isGoodQuality false when play spread is unbalanced', () => {
  const ids = Array.from({ length: 8 }, (_, i) => `p${i + 1}`)
  const schedule = rotationSchedule(ids, 6, 2, 0)
  const result = makeResult(schedule)
  // Force an unbalanced play count.
  result.playCount = { [toPlayerId('p1')]: 6 }
  assert.equal(isGoodQuality(result, playerMap(8), []), false)
})
