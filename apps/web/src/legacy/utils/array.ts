// src/utils/array.ts
// Shared array utilities.

/** Fisher-Yates shuffle — returns a new shuffled copy. */
export function shuffle<T>(arr: T[]): T[] {
  const a = [...arr]
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1))
    ;[a[i], a[j]] = [a[j], a[i]]
  }
  return a
}

/**
 * Generate all combinations of `k` elements from `arr`.
 * For small arrays (n ≤ 20, k ≤ 4) this is fast enough.
 */
export function* combinations<T>(arr: readonly T[], k: number): Generator<T[]> {
  if (k < 0 || k > arr.length) return
  if (k === 0) { yield []; return }
  for (let i = 0; i <= arr.length - k; i++) {
    for (const rest of combinations(arr.slice(i + 1), k - 1)) {
      yield [arr[i], ...rest]
    }
  }
}
