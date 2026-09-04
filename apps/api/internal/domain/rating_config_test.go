package domain

import "testing"

func TestRatingConfigValidateDefault(t *testing.T) {
	if err := DefaultRatingConfig.Validate(); err != nil {
		t.Fatalf("default config harus valid: %v", err)
	}
}

func TestRatingConfigValidateCatchesBadRanges(t *testing.T) {
	cfg := DefaultRatingConfig

	// max_delta ≤ 0
	bad := cfg
	bad.Params.MaxDelta = 0
	if err := bad.Validate(); err == nil {
		t.Fatal("max_delta=0 harus gagal")
	}

	// initial_rd di luar [rd_min, rd_max]
	bad = cfg
	bad.Params.InitialRD = 500
	if err := bad.Validate(); err == nil {
		t.Fatal("initial_rd=500 (>rd_max 350) harus gagal")
	}

	// rating_min ≥ rating_max
	bad = cfg
	bad.Params.RatingMin = 2600
	if err := bad.Validate(); err == nil {
		t.Fatal("rating_min>rating_max harus gagal")
	}

	// phase_weights kosong
	bad = cfg
	bad.PhaseWeights = map[string]float64{}
	if err := bad.Validate(); err == nil {
		t.Fatal("phase_weights kosong harus gagal")
	}

	// absent_policy tak dikenal
	bad = cfg
	bad.AbsentPolicy = AbsentPolicy("hmm")
	if err := bad.Validate(); err == nil {
		t.Fatal("absent_policy tak dikenal harus gagal")
	}

	// placeholder_policy tak dikenal
	bad = cfg
	bad.PlaceholderPolicy = PlaceholderPolicy("hmm")
	if err := bad.Validate(); err == nil {
		t.Fatal("placeholder_policy tak dikenal harus gagal")
	}
}
