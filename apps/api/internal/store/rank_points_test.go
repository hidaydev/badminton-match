package store

import "testing"

// TestGameValue — nilai game = base × (0.5 + 0.5 × margin/target).
func TestGameValue(t *testing.T) {
	const base = 250
	cases := []struct {
		name           string
		margin, target float64
		want           float64
	}{
		{"menang telak (21-0, target 21)", 21, 21, 250}, // margin/target = 1
		{"menang tipis (21-19, target 21)", 2, 21, 250 * (0.5 + 0.5*2.0/21.0)},
		{"kalah telak (0-21, target 21)", 21, 21, 250}, // margin absolut
		{"imbang (21-21)", 0, 21, 125},                 // separuh base
		{"target 0 → 0 (hindari bagi nol)", 5, 0, 0},
		// Skor bisa melebihi target (mis. 30-28 di target 21, atau target 30).
		// Tanpa jepit, margin/target > 1 membuat nilai game melampaui base
		// dan merusak skala poin.
		{"margin melebihi target dijepit", 40, 21, 250},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := gameValue(base, c.margin, c.target)
			if diff := got - c.want; diff > 1e-9 || diff < -1e-9 {
				t.Fatalf("gameValue(base=%v, margin=%v, target=%v) = %v, want %v",
					base, c.margin, c.target, got, c.want)
			}
		})
	}
}

// TestOpponentMultiplier — rata-rata rating lawan / rata-rata populasi, dijepit.
func TestOpponentMultiplier(t *testing.T) {
	clamp := [2]float64{0.5, 1.5}
	cases := []struct {
		name           string
		oppAvg, popAvg float64
		want           float64
	}{
		{"lawan setara populasi → 1.0", 1600, 1600, 1},
		{"lawan lebih kuat", 2000, 1600, 1.25},
		{"lawan lebih lemah", 1200, 1600, 0.75},
		{"lawan jauh lebih kuat → dijepit atas", 5000, 1600, 1.5},
		{"lawan jauh lebih lemah → dijepit bawah", 100, 1600, 0.5},
		{"populasi 0 → netral (hindari bagi nol)", 1600, 0, 1},
		{"lawan tanpa rating → netral", 0, 1600, 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := opponentMultiplier(c.oppAvg, c.popAvg, clamp)
			if diff := got - c.want; diff > 1e-9 || diff < -1e-9 {
				t.Fatalf("opponentMultiplier(%v, %v) = %v, want %v", c.oppAvg, c.popAvg, got, c.want)
			}
		})
	}
}

// TestSplitKey — pemisah key agregasi tidak boleh bentrok dengan isi id.
func TestSplitKey(t *testing.T) {
	pid, sid, ok := splitKey("abc\x00def")
	if !ok || pid != "abc" || sid != "def" {
		t.Fatalf("splitKey = (%q, %q, %v), want (abc, def, true)", pid, sid, ok)
	}
	// Tanpa pemisah: kembalikan apa adanya, ok=false.
	if pid, sid, ok := splitKey("tanpa-pemisah"); ok || sid != "" || pid != "tanpa-pemisah" {
		t.Fatalf("splitKey tanpa pemisah = (%q, %q, %v)", pid, sid, ok)
	}
}
