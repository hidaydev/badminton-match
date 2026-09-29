package domain

import "testing"

func TestRatingConfigValidateDefault(t *testing.T) {
	if err := DefaultRatingConfig.Validate(); err != nil {
		t.Fatalf("default config harus valid: %v", err)
	}
}

func TestRatingConfigValidateCatchesBadRanges(t *testing.T) {
	cfg := DefaultRatingConfig

	// Validasi param rating Glicko (max_delta, initial_rd, rating_min/max)
	// dihapus bersama pensiun Glicko — parameternya tidak lagi dibaca, jadi
	// tidak ada lagi jalur gagal untuk diuji. Yang diuji di sini hanya
	// invariant yang MASIH berlaku.

	// absent_policy tak dikenal
	bad := cfg
	bad.AbsentPolicy = AbsentPolicy("hmm")
	if err := bad.Validate(); err == nil {
		t.Fatal("absent_policy tak dikenal harus gagal")
	}

}
