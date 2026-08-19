package domain

import "testing"

// TIER_8_UNIFICATION.md — 8 tier: D, D+, C, C+, B, B+, A, A+.

func TestValidTier(t *testing.T) {
	valid := []string{"D", "D+", "C", "C+", "B", "B+", "A", "A+"}
	invalid := []string{"", "E", "AA", "D-", "C-", "B-", "A-", "S", "D--"}
	for _, c := range valid {
		if !ValidTier(c) {
			t.Fatalf("ValidTier(%q) = false, want true", c)
		}
	}
	for _, c := range invalid {
		if ValidTier(c) {
			t.Fatalf("ValidTier(%q) = true, want false", c)
		}
	}
}

func TestTierForRatingBands(t *testing.T) {
	c := DefaultRatingConfig
	cases := []struct {
		rating float64
		want   string
	}{
		// D = D-∪D (≤1199) · D+ 1200-1299 · C 1300-1499 · C+ 1500-1599
		{1000, "D"}, {1199, "D"}, {1200, "D+"}, {1299, "D+"},
		{1300, "C"}, {1499, "C"}, {1500, "C+"}, {1599, "C+"},
		// B 1600-1799 · B+ 1800-1899 · A 1900-2099 · A+ ≥2100
		{1600, "B"}, {1799, "B"}, {1800, "B+"}, {1899, "B+"},
		{1900, "A"}, {2099, "A"}, {2100, "A+"}, {2500, "A+"},
	}
	for _, tc := range cases {
		if got := c.TierForRating(tc.rating); got != tc.want {
			t.Fatalf("TierForRating(%v) = %q, want %q", tc.rating, got, tc.want)
		}
	}
}

func TestFloorOf(t *testing.T) {
	// Keputusan user (2026-08-19): floor = basis huruf — B+ floor di B,
	// tidak boleh turun ke C; boleh naik ke A/A+.
	cases := []struct{ tier, want string }{
		{"A+", "A"}, {"A", "A"},
		{"B+", "B"}, {"B", "B"},
		{"C+", "C"}, {"C", "C"},
		{"D+", "D"}, {"D", "D"},
		{"", ""},
	}
	for _, tc := range cases {
		if got := FloorOf(tc.tier); got != tc.want {
			t.Fatalf("FloorOf(%q) = %q, want %q", tc.tier, got, tc.want)
		}
	}
}

func TestDisplayTier(t *testing.T) {
	c := DefaultRatingConfig
	// assigned B+ → floor B. Rating turun ke zona C (1450) → tetap tampil B.
	if got := c.DisplayTier(1450, "B+"); got != "B" {
		t.Fatalf("DisplayTier(1450, B+) = %q, want B (floor)", got)
	}
	// B+ naik ke zona A (1950) → tampil A (boleh naik ke A/A+).
	if got := c.DisplayTier(1950, "B+"); got != "A" {
		t.Fatalf("DisplayTier(1950, B+) = %q, want A", got)
	}
	// assigned C, derived D+ (1250) → floor C menang.
	if got := c.DisplayTier(1250, "C"); got != "C" {
		t.Fatalf("DisplayTier(1250, C) = %q, want C (floor)", got)
	}
	// tanpa assigned → derived murni.
	if got := c.DisplayTier(1450, ""); got != "C" {
		t.Fatalf("DisplayTier(1450, '') = %q, want C", got)
	}
}

func TestMidRatingForTier(t *testing.T) {
	c := DefaultRatingConfig
	// Baseline = nilai forming (session_tier_init) — konsisten ingest/rebuild.
	cases := map[string]float64{
		"D": 1150, "D+": 1250, "C": 1450, "C+": 1550,
		"B": 1750, "B+": 1850, "A": 2050, "A+": 2150,
	}
	for tier, want := range cases {
		got, ok := c.MidRatingForTier(tier)
		if !ok || got != want {
			t.Fatalf("MidRatingForTier(%q) = %v,%v want %v", tier, got, ok, want)
		}
	}
	if _, ok := c.MidRatingForTier("X"); ok {
		t.Fatal("MidRatingForTier(X) harus false")
	}
}

func TestFormingForTier(t *testing.T) {
	c := DefaultRatingConfig
	init, ok := c.FormingForTier("B+")
	if !ok || init.Rating != 1850 || init.Class != "B+" {
		t.Fatalf("FormingForTier(B+) = %+v want rating 1850 class B+", init)
	}
	if _, ok := c.FormingForTier("S"); ok {
		t.Fatal("FormingForTier(S) harus false")
	}
}

func TestRatingConfigValidateWithSeason(t *testing.T) {
	if err := DefaultRatingConfig.Validate(); err != nil {
		t.Fatalf("default config harus valid: %v", err)
	}
	bad := DefaultRatingConfig
	bad.SessionTierInit = map[string]TierInit{"D": {Class: "ZZ", Rating: 1150}}
	if err := bad.Validate(); err == nil {
		t.Fatal("session_tier_init invalid harus gagal")
	}
	bad2 := DefaultRatingConfig
	bad2.ClassBands = map[string][2]*float64{} // kosong
	if err := bad2.Validate(); err == nil {
		t.Fatal("class_bands kosong harus gagal")
	}
	bad3 := DefaultRatingConfig
	bad3.SessionTierInit = map[string]TierInit{"D": {Class: "D", Rating: 1150}} // cuma 1 dari 8
	if err := bad3.Validate(); err == nil {
		t.Fatal("session_tier_init kurang dari 8 harus gagal")
	}
}
