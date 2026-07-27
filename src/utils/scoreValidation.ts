// src/utils/scoreValidation.ts
// Single source of truth for game score validation rules.

export function validateScore(a: number, b: number): string | null {
  if (a === b) return 'Scores cannot be equal'
  if (a < 0 || b < 0) return 'Scores cannot be negative'
  return null
}
