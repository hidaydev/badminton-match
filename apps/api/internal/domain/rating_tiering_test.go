package domain

import "testing"

func TestValidClass(t *testing.T) {
	valid := []string{"D-", "D", "D+", "C-", "C", "C+", "B-", "B", "B+", "A-", "A", "A+"}
	invalid := []string{"", "E", "AA", "D--", "S"}
	for _, c := range valid {
		if !ValidClass(c) {
			t.Fatalf("ValidClass(%q) = false, want true", c)
		}
	}
	for _, c := range invalid {
		if ValidClass(c) {
			t.Fatalf("ValidClass(%q) = true, want false", c)
		}
	}
}

func TestClassForRatingBands(t *testing.T) {
	c := DefaultRatingConfig
	cases := []struct {
		rating float64
		want   string
	}{
		{1000, "D-"}, {1099, "D-"}, {1100, "D"}, {1199, "D"}, {1200, "D+"},
		{1300, "C-"}, {1400, "C"}, {1500, "C+"}, {1600, "B-"}, {1700, "B"},
		{1800, "B+"}, {1900, "A-"}, {2000, "A"}, {2100, "A+"}, {2500, "A+"},
	}
	for _, tc := range cases {
		if got := c.ClassForRating(tc.rating); got != tc.want {
			t.Fatalf("ClassForRating(%v) = %q, want %q", tc.rating, got, tc.want)
		}
	}
}

func TestFloorOf(t *testing.T) {
	cases := []struct{ class, want string }{
		{"C", "C-"}, {"C+", "C-"}, {"C-", "C-"},
		{"B", "B-"}, {"A", "A-"}, {"A+", "A-"}, {"D", "D-"},
		{"", ""},
	}
	for _, tc := range cases {
		if got := FloorOf(tc.class); got != tc.want {
			t.Fatalf("FloorOf(%q) = %q, want %q", tc.class, got, tc.want)
		}
	}
}

func TestDisplayClass(t *testing.T) {
	c := DefaultRatingConfig
	// derived D+ (1250) tapi assigned C → floor C- > D+ → tampil C-
	if got := c.DisplayClass(1250, "C"); got != "C-" {
		t.Fatalf("DisplayClass(1250, C) = %q, want C-", got)
	}
	// derived B- (1650) > floor C- → tampil derived
	if got := c.DisplayClass(1650, "C"); got != "B-" {
		t.Fatalf("DisplayClass(1650, C) = %q, want B-", got)
	}
	// assigned A, derived D+ → floor A- menang
	if got := c.DisplayClass(1250, "A"); got != "A-" {
		t.Fatalf("DisplayClass(1250, A) = %q, want A-", got)
	}
	// tanpa assigned → derived murni
	if got := c.DisplayClass(1450, ""); got != "C" {
		t.Fatalf("DisplayClass(1450, '') = %q, want C", got)
	}
}

func TestRatingConfigValidateWithSeason(t *testing.T) {
	if err := DefaultRatingConfig.Validate(); err != nil {
		t.Fatalf("default config harus valid: %v", err)
	}
	bad := DefaultRatingConfig
	bad.SessionTierInit = map[string]TierInit{"1": {Class: "ZZ", Rating: 2050}}
	if err := bad.Validate(); err == nil {
		t.Fatal("session_tier_init invalid harus gagal")
	}
	bad2 := DefaultRatingConfig
	bad2.ClassBands = map[string][2]*float64{} // kosong
	if err := bad2.Validate(); err == nil {
		t.Fatal("class_bands kosong harus gagal")
	}
}
