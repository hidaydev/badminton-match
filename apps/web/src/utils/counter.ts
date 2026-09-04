// src/utils/counter.ts
// Shared symmetric co-occurrence counter.

/**
 * Increment the co-occurrence count between `a` and `b` in both directions.
 * Mutates `obj` in place: obj[a][b]++ and obj[b][a]++.
 */
export function bumpCoOccurrence(
  obj: Record<string, Record<string, number>>,
  a: string,
  b: string,
) {
  obj[a] ??= {}
  obj[a][b] = (obj[a][b] ?? 0) + 1
  obj[b] ??= {}
  obj[b][a] = (obj[b][a] ?? 0) + 1
}
