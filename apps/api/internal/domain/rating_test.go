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
	p := DefaultRatingParams
	// rd=30: 7 hari → sqrt(900+15²·7²)=sqrt(900+11025)=sqrt(11925)=109.20
	if got := GrowRD(30, 7, p); math.Abs(got-109.20) > 0.01 {
		t.Fatalf("GrowRD(30,7) = %v, want ≈109.2", got)
	}
	// 13 hari → sqrt(38925)=197.30
	if got := GrowRD(30, 13, p); math.Abs(got-197.30) > 0.01 {
		t.Fatalf("GrowRD(30,13) = %v, want ≈197.3", got)
	}
	// 23 hari → sqrt(119925)=346.30
	if got := GrowRD(30, 23, p); math.Abs(got-346.30) > 0.01 {
		t.Fatalf("GrowRD(30,23) = %v, want ≈346.3", got)
	}
	// 24 hari → 361.3 → capped 350
	if got := GrowRD(30, 24, p); got != 350 {
		t.Fatalf("GrowRD(30,24) = %v, want 350 (cap)", got)
	}
	// idle 0 → tidak berubah
	if got := GrowRD(123, 0, p); got != 123 {
		t.Fatalf("GrowRD(123,0) = %v, want 123", got)
	}
}

func TestGlickoUpdateGolden(t *testing.T) {
	p := DefaultRatingParams
	// Pemain baru 1250/350 menang lawan 1250/350, movm=1, w=1:
	// E=0.5, g=0.669, d²=269651, factor=484.88, raw=162.2 → CAP 60
	st, delta := GlickoUpdate(
		RatingState{Rating: 1250, RD: 350},
		[]RatingOpponent{{Rating: 1250, RD: 350}},
		OutcomeWin, 1.0, 1.0, p,
	)
	if delta != 60 {
		t.Fatalf("delta = %v, want 60 (cap)", delta)
	}
	if st.Rating != 1310 {
		t.Fatalf("rating = %v, want 1310", st.Rating)
	}
	// newRD = sqrt(1/(1/350²+1/269651)) = sqrt(84233) = 290.23
	if math.Abs(st.RD-290.23) > 0.01 {
		t.Fatalf("rd = %v, want ≈290.23", st.RD)
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
	// provisional rd=350, whitewash (movm 1.5) + final (w=1.25) → raw ~304 → cap
	_, delta := GlickoUpdate(
		RatingState{Rating: 1250, RD: 350},
		[]RatingOpponent{{Rating: 1250, RD: 350}},
		OutcomeWin, 1.5, 1.25, p,
	)
	if delta != 60 {
		t.Fatalf("delta = %v, want 60 (cap melindungi swing provisional)", delta)
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
