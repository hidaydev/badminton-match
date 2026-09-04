package domain

import (
	"math"
	"testing"
)

// ── Golden + property tests Glicko-1-lite (RATING_ENGINE_DESIGN.md §3) ────
// Nilai golden dihitung manual dari rumus (lihat komentar tiap test).

func TestG(t *testing.T) {
	// g(350) = 1/sqrt(1+3q²·350²/π²); q=ln10/400
	// 3q²·122500/π² = 12.1786/9.8696 = 1.2340 → g = 1/1.4947 = 0.6690
	got := G(350)
	if math.Abs(got-0.6690) > 0.001 {
		t.Fatalf("G(350) = %v, want ≈0.6690", got)
	}
	// g(30): 3q²·900/π² = 0.0895/9.8696 = 0.00907 → g = 1/1.00453 = 0.9955
	got30 := G(30)
	if math.Abs(got30-0.9955) > 0.0005 {
		t.Fatalf("G(30) = %v, want ≈0.9955", got30)
	}
}

func TestExpectedScore(t *testing.T) {
	// E = 1/(1+10^(−g(rd)·(r−r_j)/400))
	// sama rating & rd → 0.5
	if e := ExpectedScore(1250, RatingOpponent{Rating: 1250, RD: 350}); math.Abs(e-0.5) > 1e-9 {
		t.Fatalf("E equal = %v, want 0.5", e)
	}
	// favorite 1500 vs 1300 (rd kecil): E > 0.76 (Glicko: g≈1 → 10^(−200/400)=0.316 → E=0.760)
	e := ExpectedScore(1500, RatingOpponent{Rating: 1300, RD: 30})
	if e < 0.75 || e > 0.77 {
		t.Fatalf("E favorite = %v, want ≈0.76", e)
	}
	// underdog: 1−E
	if math.Abs(e+ExpectedScore(1300, RatingOpponent{Rating: 1500, RD: 30})-1) > 1e-9 {
		t.Fatal("E simetris (1−E)")
	}
}

func TestMarginOfVictory(t *testing.T) {
	p := DefaultRatingParams
	cases := []struct {
		a, b, target int
		want         float64
	}{
		{21, 19, 21, 0.5 + 2.0/21.0}, // 0.5952
		{30, 28, 30, 0.5 + 2.0/30.0}, // 0.5667
		{42, 40, 42, 0.5 + 2.0/42.0}, // 0.5476
		{21, 0, 21, 1.5},             // m=1 → 1.5
		{30, 0, 21, 0.5 + 30.0/21.0}, // m=1.43 → 1.9286 (belum cap)
		{40, 0, 21, 2.0},             // m=1.90 → 2.40 → cap 2.0
	}
	for _, c := range cases {
		got := MarginOfVictory(c.a, c.b, c.target, p)
		if math.Abs(got-c.want) > 1e-9 {
			t.Fatalf("MoVM(%d-%d,target %d) = %v, want %v", c.a, c.b, c.target, got, c.want)
		}
	}
}

func TestGrowRD(t *testing.T) {
	p := DefaultRatingParams // rd_growth = 3/hari (T2 rekalibrasi)
	// rd=30: 7 hari → sqrt(900+(3·7)²)=sqrt(900+441)=sqrt(1341)=36.62
	if got := GrowRD(30, 7, p); math.Abs(got-36.62) > 0.01 {
		t.Fatalf("GrowRD(30,7) = %v, want ≈36.6", got)
	}
	// 30 hari → sqrt(900+8100)=sqrt(9000)=94.87
	if got := GrowRD(30, 30, p); math.Abs(got-94.87) > 0.01 {
		t.Fatalf("GrowRD(30,30) = %v, want ≈94.9", got)
	}
	// 116 hari → sqrt(900+(3·116)²)=sqrt(900+121104)=sqrt(122004)=349.3 → ~cap
	if got := GrowRD(30, 116, p); math.Abs(got-349.3) > 1 {
		t.Fatalf("GrowRD(30,116) = %v, want ≈349.3", got)
	}
	// idle 0 → tidak berubah
	if got := GrowRD(123, 0, p); got != 123 {
		t.Fatalf("GrowRD(123,0) = %v, want 123", got)
	}
}

func TestGlickoUpdateGolden(t *testing.T) {
	p := DefaultRatingParams // initial_rd 220, cap 30 (T2)
	// Pemain baru 1250/220 menang lawan 1250/220, movm=1, w=1:
	// raw ≈ 90 → CAP 30; newRD ≈ 195.3
	st, delta := GlickoUpdate(
		RatingState{Rating: 1250, RD: 220},
		[]RatingOpponent{{Rating: 1250, RD: 220}},
		OutcomeWin, 1.0, 1.0, p,
	)
	if delta != 30 {
		t.Fatalf("delta = %v, want 30 (cap)", delta)
	}
	if st.Rating != 1280 {
		t.Fatalf("rating = %v, want 1280", st.Rating)
	}
	if math.Abs(st.RD-195.3) > 0.5 {
		t.Fatalf("rd = %v, want ≈195.3", st.RD)
	}
}

func TestGlickoUpdateZeroSumEqualStates(t *testing.T) {
	p := DefaultRatingParams
	// Dua pemain identik (1250/200), movm=1, w=1 → winner +X, loser −X
	winner, dw := GlickoUpdate(
		RatingState{Rating: 1250, RD: 200},
		[]RatingOpponent{{Rating: 1250, RD: 200}},
		OutcomeWin, 1.0, 1.0, p,
	)
	loser, dl := GlickoUpdate(
		RatingState{Rating: 1250, RD: 200},
		[]RatingOpponent{{Rating: 1250, RD: 200}},
		OutcomeLoss, 1.0, 1.0, p,
	)
	if dw != -dl {
		t.Fatalf("bukan zero-sum untuk state identik: +%v vs %v", dw, dl)
	}
	if math.Abs(winner.Rating-1250-dw) > 1e-6 || math.Abs(loser.Rating-1250-dl) > 1e-6 {
		t.Fatal("rating baru tidak konsisten dengan delta")
	}
	if math.Abs(winner.RD-loser.RD) > 1e-6 {
		t.Fatalf("RD harus simetris: %v vs %v", winner.RD, loser.RD)
	}
}

func TestGlickoUpdateCapWhitewashFinal(t *testing.T) {
	p := DefaultRatingParams
	// provisional rd=220, whitewash (movm 1.5) + final (w=1.25) → raw besar → cap 30
	_, delta := GlickoUpdate(
		RatingState{Rating: 1250, RD: 220},
		[]RatingOpponent{{Rating: 1250, RD: 220}},
		OutcomeWin, 1.5, 1.25, p,
	)
	if delta != 30 {
		t.Fatalf("delta = %v, want 30 (cap melindungi swing provisional)", delta)
	}
}

func TestGlickoUpdateClamp(t *testing.T) {
	p := DefaultRatingParams
	// rating maks: menang terus → tetap ≤ 2500
	st := RatingState{Rating: 2498, RD: 30}
	for i := 0; i < 5; i++ {
		next, _ := GlickoUpdate(
			st,
			[]RatingOpponent{{Rating: 1200, RD: 30}},
			OutcomeWin, 1.5, 1.25, p,
		)
		st = next
	}
	if st.Rating > 2500 {
		t.Fatalf("rating = %v, melewati clamp 2500", st.Rating)
	}
	// rating minimum: kalah terus → tetap ≥ 1000
	st = RatingState{Rating: 1002, RD: 30}
	for i := 0; i < 5; i++ {
		next, _ := GlickoUpdate(
			st,
			[]RatingOpponent{{Rating: 2490, RD: 30}},
			OutcomeLoss, 1.5, 1.25, p,
		)
		st = next
	}
	if st.Rating < 1000 {
		t.Fatalf("rating = %v, melewati clamp 1000", st.Rating)
	}
}

func TestGlickoUpdateUnderdogWinBigger(t *testing.T) {
	p := DefaultRatingParams
	// Underdog (1100) menang vs favorite (1600) → delta lebih besar daripada
	// favorite menang vs underdog (asimetri expected).
	underdogWin, _ := GlickoUpdate(
		RatingState{Rating: 1100, RD: 100},
		[]RatingOpponent{{Rating: 1600, RD: 100}},
		OutcomeWin, 1.0, 1.0, p,
	)
	favoriteWin, _ := GlickoUpdate(
		RatingState{Rating: 1600, RD: 100},
		[]RatingOpponent{{Rating: 1100, RD: 100}},
		OutcomeWin, 1.0, 1.0, p,
	)
	if !(underdogWin.Rating-1100 > favoriteWin.Rating-1600) {
		t.Fatalf("underdog win (%v) harus lebih besar dari favorite win (%v)",
			underdogWin.Rating-1100, favoriteWin.Rating-1600)
	}
}

func TestGlickoUpdateDeterministic(t *testing.T) {
	p := DefaultRatingParams
	st := RatingState{Rating: 1300, RD: 150}
	opps := []RatingOpponent{{Rating: 1250, RD: 220}, {Rating: 1400, RD: 90}}
	a, _ := GlickoUpdate(st, opps, OutcomeWin, 0.6, 1.05, p)
	b, _ := GlickoUpdate(st, opps, OutcomeWin, 0.6, 1.05, p)
	if a != b {
		t.Fatalf("harus deterministik: %+v vs %+v", a, b)
	}
	// expected round4 → semua output round2/4 (tidak ada float noise)
	for _, v := range []float64{a.Rating, a.RD} {
		if v != round2(v) {
			t.Fatalf("output tidak round2: %v", v)
		}
	}
}
