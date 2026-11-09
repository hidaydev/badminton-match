// src/legacy/utils/scoreValidation.ts
// The single-game rules the score editor checks before it writes.
// The server owns the same table in `modules/session/scoring.nim`
// (`setVerdict`): equal scores, range, and the format's points/cap/win-by.
// This file mirrors only the two rules the v1 editor can break on its own; the
// table both sides must agree on is `./__tests__/scoreValidation.test.ts`
// against `modules/session/tests/scoring_test.nim`.
export function validateScore(a: number, b: number): string | null {
  if (a === b) return 'Scores cannot be equal'
  if (a < 0 || b < 0) return 'Scores cannot be negative'
  if (a > 99 || b > 99) return 'Scores must be between 0 and 99'
  return null
}
