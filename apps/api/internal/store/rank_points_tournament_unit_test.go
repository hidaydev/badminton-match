package store

import "testing"

// TestTournResultKey — pemetaan fase+outcome → kunci rasio §4.4.
func TestTournResultKey(t *testing.T) {
	cases := []struct {
		name     string
		best     int
		finalOut string
		anyWin   bool
		want     string
	}{
		{"juara: menang final", 4, "W", true, "final"},
		{"runner-up: kalah final tapi menang sebelumnya", 4, "L", true, "runner_up"},
		{"gugur semifinal", 3, "", true, "sf"},
		{"juara-3 (kalah SF, menang 3rd)", 3, "", true, "sf"},
		{"gugur quarter", 2, "", true, "qf"},
		{"gugur grup tapi pernah menang", 1, "", true, "group"},
		{"ikut tanpa satu kemenangan pun", 1, "", false, "participant"},
		{"tanpa kemenangan walau fase tak dikenal", 0, "", false, "participant"},
		{"fase tak dikenal tapi pernah menang", 0, "", true, "participant"},
	}
	for _, c := range cases {
		if got := tournResultKey(c.best, c.finalOut, c.anyWin); got != c.want {
			t.Errorf("%s: tournResultKey(%d,%q,%v) = %q, want %q",
				c.name, c.best, c.finalOut, c.anyWin, got, c.want)
		}
	}
}

// TestTournPhaseRank — peringkat fase; 3rd setara sf (pengikutnya kalah SF).
func TestTournPhaseRank(t *testing.T) {
	cases := map[string]int{
		"final": 4, "sf": 3, "3rd": 3, "qf": 2, "group": 1,
		"regular": 0, "": 0, "unknown": 0,
	}
	for phase, want := range cases {
		if got := tournPhaseRank(phase); got != want {
			t.Errorf("tournPhaseRank(%q) = %d, want %d", phase, got, want)
		}
	}
}

// TestRankLevelRatioOf — data menang; kunci hilang → default §4.4; kunci
// asing → 0.
func TestRankLevelRatioOf(t *testing.T) {
	lv := rankLevel{champion: 15000, ratios: map[string]float64{"final": 0.9}}
	if got := lv.ratioOf("final"); got != 0.9 {
		t.Errorf("ratioOf(final) dari data = %v, want 0.9", got)
	}
	// runner_up tidak ada di data (kasus prod) → default 0.85
	if got := lv.ratioOf("runner_up"); got != 0.85 {
		t.Errorf("ratioOf(runner_up) fallback = %v, want 0.85", got)
	}
	if got := lv.ratioOf("tak-ada"); got != 0 {
		t.Errorf("ratioOf(tak-ada) = %v, want 0", got)
	}
}
