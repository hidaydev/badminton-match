package domain

import "errors"

// ── Aturan skor game ────────────────────────────────────────────────────────
// Source of truth backend untuk validasi skor (mirror src/utils/scoreValidation.ts
// di frontend). Mutasi granular (SetScore dkk.) dihapus — app mengirim snapshot
// lengkap via PUT; validasi penuh di ValidateSnapshot.

var (
	errScoresEqual    = errors.New("scores cannot be equal")
	errScoresNegative = errors.New("scores cannot be negative")
	errScoresTooHigh  = errors.New("scores must be between 0 and 99")
)

// ValidateScore — aturan skor: tidak boleh sama, tidak boleh negatif, max 99
// (konsisten dengan CHECK constraint scheduled_games di DB).
func ValidateScore(a, b int) error {
	if a == b {
		return errScoresEqual
	}
	if a < 0 || b < 0 {
		return errScoresNegative
	}
	if a > 99 || b > 99 {
		return errScoresTooHigh
	}
	return nil
}
