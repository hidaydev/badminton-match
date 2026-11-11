/**
 * The one rendering of a point difference. A standings cell shows a signed
 * number, and the zero has no sign: `+5`, `0`, `-3`. It used to be written out
 * at every ledger, with one of them printing a dash for zero.
 */
export function formatDiff(value: number): string {
  if (value > 0) return `+${value}`
  return String(value)
}
