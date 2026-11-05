import { GROUP_IDS, type GroupId } from '../apps/web/src/legacy/utils/tournament'

/**
 * v1 `drawGroups`: shuffle the 16 pair ids, then cut the result into four
 * consecutive chunks of four. The wizard's implementation lived with the
 * classic tournament screens that the legacy rewrite removed, so the fixture
 * keeps its own copy of this one rule; the rest of the draw
 * (round robin, bracket slots) still comes from `legacy/utils/tournament` so it
 * cannot drift from what the server validates.
 *
 * The seed is explicit so the same pairs always land in the same groups: a
 * visual baseline cannot survive a fixture that reshuffles on every run.
 */

const PAIR_COUNT = 16
const GROUP_SIZE = 4

/** mulberry32: small, no state outside the closure, stable across engines. */
function seededRandom(seed: number): () => number {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let value = state
    value = Math.imul(value ^ (value >>> 15), value | 1)
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61)
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296
  }
}

function shuffle<T>(items: readonly T[], seed: number): T[] {
  const random = seededRandom(seed)
  const result = [...items]
  for (let index = result.length - 1; index > 0; index -= 1) {
    const swapIndex = Math.floor(random() * (index + 1))
    const held = result[index]
    result[index] = result[swapIndex]
    result[swapIndex] = held
  }
  return result
}

export function drawGroups(pairIds: readonly string[], seed: number): Record<GroupId, string[]> {
  if (pairIds.length !== PAIR_COUNT) {
    throw new Error('a classic draw needs exactly 16 pairs')
  }
  const groups: Record<GroupId, string[]> = { A: [], B: [], C: [], D: [] }
  shuffle(pairIds, seed).forEach((pairId, index) => {
    groups[GROUP_IDS[Math.floor(index / GROUP_SIZE)]].push(pairId)
  })
  return groups
}