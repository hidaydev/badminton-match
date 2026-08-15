// src/utils/scoreValidation.ts
// Aturan skor game — MIRROR ValidateScore di majadu-api/internal/domain/transform.go.
// Dua sisi harus selalu konsisten (lihat scripts/tests/scoreValidation.test.ts).
export function validateScore(a: number, b: number): string | null {
  if (a === b) return 'Scores cannot be equal'
  if (a < 0 || b < 0) return 'Scores cannot be negative'
  if (a > 99 || b > 99) return 'Scores must be between 0 and 99'
  return null
}
