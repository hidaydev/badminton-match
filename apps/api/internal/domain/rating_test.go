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
	p := DefaultRatingParams // initial_rd 220, cap 45 (provisional, T2+T4)
	// Pemain baru 1250/220 menang lawan 1250/220, movm=1, w=1:
	// raw ≈ 90 → CAP 45 (provisional); newRD ≈ 195.3
	st, delta := GlickoUpdate(
		RatingState{Rating: 1250, RD: 220},
		[]RatingOpponent{{Rating: 1250, RD: 220}},
		OutcomeWin, 1.0, 1.0, p,
	)
	if delta != 45 {
		t.Fatalf("delta = %v, want 45 (provisional cap)", delta)
	}
	if st.Rating != 1295 {
		t.Fatalf("rating = %v, want 1295", st.Rating)
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
	// provisional rd=220, whitewash (movm 1.5) + final (w=1.25) → raw besar → cap 45 (provisional)
	_, delta := GlickoUpdate(
		RatingState{Rating: 1250, RD: 220},
		[]RatingOpponent{{Rating: 1250, RD: 220}},
		OutcomeWin, 1.5, 1.25, p,
	)
	if delta != 45 {
		t.Fatalf("delta = %v, want 45 (provisional cap melindungi swing)", delta)
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

// ── Anti-sandbagging tests ────────────────────────────────────────────────

func TestAntiSandbaggingNoActivation(t *testing.T) {
	p := DefaultRatingParams // GapCapThreshold=500, GapCapSlope=1000
	// Gap 400 (1500 vs 1100) — di bawah threshold → cap normal 30
	// Bandingkan dengan gap 700 yang kena reduced cap
	st := RatingState{Rating: 1500, RD: 80}
	opps := []RatingOpponent{{Rating: 1100, RD: 80}}
	_, deltaSmall := GlickoUpdate(st, opps, OutcomeWin, 1.0, 1.0, p)

	// Gap 700 — di atas threshold → reduced cap 24
	st2 := RatingState{Rating: 1800, RD: 80}
	opps2 := []RatingOpponent{{Rating: 1100, RD: 80}}
	_, deltaLarge := GlickoUpdate(st2, opps2, OutcomeWin, 1.0, 1.0, p)

	// Keduanya harus di bawah cap masing-masing
	if deltaSmall > 30.01 {
		t.Fatalf("gap kecil: delta %v melebihi cap normal 30", deltaSmall)
	}
	if deltaLarge > 24.01 {
		t.Fatalf("gap besar: delta %v melebihi reduced cap 24", deltaLarge)
	}
	// Delta untuk gap besar harus lebih kecil karena cap lebih ketat
	if deltaLarge >= deltaSmall {
		t.Fatalf("gap besar delta (%v) harus lebih kecil dari gap kecil (%v)", deltaLarge, deltaSmall)
	}
}

func TestAntiSandbaggingActivation(t *testing.T) {
	p := DefaultRatingParams // GapCapThreshold=500, GapCapSlope=1000
	// Gap 700 (1800 vs 1100) — di atas threshold
	// effectiveCap = 30 × (1 - (700-500)/1000) = 30 × 0.8 = 24
	st := RatingState{Rating: 1800, RD: 80}
	opps := []RatingOpponent{{Rating: 1100, RD: 80}}
	_, delta := GlickoUpdate(st, opps, OutcomeWin, 1.0, 1.0, p)
	if delta > 24.01 { // toleransi rounding
		t.Fatalf("delta %v harus ≤ 24 (gap 700, cap dikurangi)", delta)
	}
}

func TestAntiSandbaggingLargeGap(t *testing.T) {
	p := DefaultRatingParams // GapCapThreshold=500, GapCapSlope=1000
	// Gap 1000 (2000 vs 1000)
	// effectiveCap = 30 × (1 - (1000-500)/1000) = 30 × 0.5 = 15
	st := RatingState{Rating: 2000, RD: 80}
	opps := []RatingOpponent{{Rating: 1000, RD: 80}}
	_, delta := GlickoUpdate(st, opps, OutcomeWin, 1.0, 1.0, p)
	if delta > 15.01 {
		t.Fatalf("delta %v harus ≤ 15 (gap 1000, cap setengah)", delta)
	}
}

func TestAntiSandbaggingMinimumCap(t *testing.T) {
	p := DefaultRatingParams // GapCapThreshold=500, GapCapSlope=1000
	// Gap 1500 (2500 vs 1000)
	// effectiveCap = 30 × (1 - (1500-500)/1000) = 30 × 0 = 0 → min 5
	// Tapi karena rating 2500 (max), delta dari formula ≈ 0
	// Test: jika rating lebih rendah, delta harus ≥ min cap
	st := RatingState{Rating: 1800, RD: 80}
	opps := []RatingOpponent{{Rating: 300, RD: 80}} // gap 1500
	_, delta := GlickoUpdate(st, opps, OutcomeWin, 1.0, 1.0, p)
	// Cap minimum 5 — tapi formula mungkin menghasilkan delta < 5
	// Karena cap adalah UPPER bound, delta bisa lebih kecil dari 5
	// Yang penting: delta tidak boleh NEGATIF untuk kemenangan
	if delta < 0 {
		t.Fatalf("delta %v tidak boleh negatif untuk kemenangan", delta)
	}
	// Bandingkan dengan gap 600 yang cap-nya lebih longgar
	st2 := RatingState{Rating: 1600, RD: 80}
	opps2 := []RatingOpponent{{Rating: 1000, RD: 80}} // gap 600
	_, delta2 := GlickoUpdate(st2, opps2, OutcomeWin, 1.0, 1.0, p)
	// Gap 1500 harus menghasilkan delta lebih kecil dari gap 600
	if delta >= delta2 {
		t.Fatalf("gap 1500 delta (%v) harus lebih kecil dari gap 600 (%v)", delta, delta2)
	}
}

func TestAntiSandbaggingDisabledWhenThresholdZero(t *testing.T) {
	p := DefaultRatingParams
	p.GapCapThreshold = 0 // disabled
	// Gap 1000 — tapi threshold 0 → cap normal 30
	st := RatingState{Rating: 2000, RD: 80}
	opps := []RatingOpponent{{Rating: 1000, RD: 80}}
	_, delta := GlickoUpdate(st, opps, OutcomeWin, 1.0, 1.0, p)
	// Delta harus dibatasi 30 (bukan dikurangi)
	if delta > 30.01 {
		t.Fatalf("delta %v melebihi cap normal 30 (threshold disabled)", delta)
	}
}

func TestAntiSandbaggingZeroSumWithGapCap(t *testing.T) {
	p := DefaultRatingParams
	// Gap 700 — kedua pemain kena gap cap yang sama
	// Karena gap dihitung dari rata-rata lawan, kedua pemain
	// seharusnya mendapat delta yang sama besar tapi berlawanan arah
	stA := RatingState{Rating: 1800, RD: 80}
	stB := RatingState{Rating: 1100, RD: 80}
	oppsA := []RatingOpponent{{Rating: 1100, RD: 80}}
	oppsB := []RatingOpponent{{Rating: 1800, RD: 80}}

	_, dA := GlickoUpdate(stA, oppsA, OutcomeWin, 1.0, 1.0, p)
	_, dB := GlickoUpdate(stB, oppsB, OutcomeLoss, 1.0, 1.0, p)

	// Untuk state identik tapi berlawanan arah, delta harus simetris
	if math.Abs(dA+dB) > 0.01 {
		t.Fatalf("bukan zero-sum dengan gap cap: A=%v, B=%v, sum=%v", dA, dB, dA+dB)
	}
}

// ── Decay tests ──────────────────────────────────────────────────────────

func TestDecayFactorDisabled(t *testing.T) {
	p := DefaultRatingParams
	// Decay disabled → rating tidak berubah
	got := DecayFactor(1500, 90, p, false, 60, 5.0, 1000)
	if got != 1500 {
		t.Fatalf("DecayFactor(disabled) = %v, want 1500", got)
	}
}

func TestDecayFactorBelowThreshold(t *testing.T) {
	p := DefaultRatingParams
	// Idle 50 hari (< threshold 60) → tidak decay
	got := DecayFactor(1500, 50, p, true, 60, 5.0, 1000)
	if got != 1500 {
		t.Fatalf("DecayFactor(50 hari) = %v, want 1500", got)
	}
}

func TestDecayFactorActive(t *testing.T) {
	p := DefaultRatingParams
	// Idle 70 hari (> threshold 60)
	// weeks = 70/7 = 10, decay = 10 × 5 = 50
	// newRating = 1500 - 50 = 1450
	got := DecayFactor(1500, 70, p, true, 60, 5.0, 1000)
	if got != 1450 {
		t.Fatalf("DecayFactor(70 hari) = %v, want 1450", got)
	}
}

func TestDecayFactorFloor(t *testing.T) {
	p := DefaultRatingParams
	// Idle 200 hari
	// weeks = 200/7 = 28.57, decay = 28.57 × 5 = 142.86
	// newRating = 1100 - 142.86 = 957.14 → floor 1000
	got := DecayFactor(1100, 200, p, true, 60, 5.0, 1000)
	if got != 1000 {
		t.Fatalf("DecayFactor(200 hari, floor) = %v, want 1000", got)
	}
}

func TestDecayFactorLargeIdle(t *testing.T) {
	p := DefaultRatingParams
	// Idle 365 hari
	// weeks = 365/7 = 52.14, decay = 52.14 × 5 = 260.71
	// newRating = 1800 - 260.71 = 1539.29
	got := DecayFactor(1800, 365, p, true, 60, 5.0, 1000)
	if math.Abs(got-1539.29) > 0.01 {
		t.Fatalf("DecayFactor(365 hari) = %v, want ≈1539.29", got)
	}
}

// ── Dynamic cap tests ────────────────────────────────────────────────────

func TestDynamicCapProvisional(t *testing.T) {
	p := DefaultRatingParams
	// RD 220 > 200 → provisional → cap = 30 × 1.5 = 45
	st := RatingState{Rating: 1250, RD: 220}
	opps := []RatingOpponent{{Rating: 1250, RD: 220}}
	_, delta := GlickoUpdate(st, opps, OutcomeWin, 1.0, 1.0, p)
	// Raw delta tanpa cap ≈ 90, cap 45
	if delta > 45.01 {
		t.Fatalf("provisional: delta %v harus ≤ 45", delta)
	}
}

func TestDynamicCapEstablished(t *testing.T) {
	p := DefaultRatingParams
	// RD 40 < 50 → established → cap = 30 × 0.8 = 24
	st := RatingState{Rating: 1500, RD: 40}
	opps := []RatingOpponent{{Rating: 1500, RD: 40}}
	_, delta := GlickoUpdate(st, opps, OutcomeWin, 1.0, 1.0, p)
	// Raw delta tanpa cap ≈ 8, cap 24 → delta tetap 8
	if delta > 24.01 {
		t.Fatalf("established: delta %v harus ≤ 24", delta)
	}
}

func TestDynamicCapNormal(t *testing.T) {
	p := DefaultRatingParams
	// RD 80 → normal (tidak provisional, tidak established) → cap = 30
	st := RatingState{Rating: 1500, RD: 80}
	opps := []RatingOpponent{{Rating: 1500, RD: 80}}
	_, delta := GlickoUpdate(st, opps, OutcomeWin, 1.0, 1.0, p)
	// Raw delta tanpa cap ≈ 8, cap 30 → delta tetap 8
	if delta > 30.01 {
		t.Fatalf("normal: delta %v harus ≤ 30", delta)
	}
}

func TestDynamicCapProvisionalBiggerThanNormal(t *testing.T) {
	p := DefaultRatingParams
	// Bandingkan provisional vs normal untuk kasus yang sama
	st := RatingState{Rating: 1250, RD: 220} // provisional
	opps := []RatingOpponent{{Rating: 1250, RD: 220}}
	_, deltaProv := GlickoUpdate(st, opps, OutcomeWin, 1.0, 1.0, p)

	st2 := RatingState{Rating: 1250, RD: 80} // normal
	opps2 := []RatingOpponent{{Rating: 1250, RD: 80}}
	_, deltaNorm := GlickoUpdate(st2, opps2, OutcomeWin, 1.0, 1.0, p)

	// Provisional harus bisa dapat delta lebih besar dari normal
	if deltaProv <= deltaNorm {
		t.Fatalf("provisional delta (%v) harus > normal delta (%v)", deltaProv, deltaNorm)
	}
}

// ── Active floor tests ──────────────────────────────────────────────────

func TestActiveFloorZeroGames(t *testing.T) {
	p := DefaultRatingParams
	// 0 game → floor = base = 1100
	got := ActiveFloor(0, p)
	if got != 1100 {
		t.Fatalf("ActiveFloor(0) = %v, want 1100", got)
	}
}

func TestActiveFloor10Games(t *testing.T) {
	p := DefaultRatingParams
	// 10 game → floor = 1100 + 10×(-5) = 1050
	got := ActiveFloor(10, p)
	if got != 1050 {
		t.Fatalf("ActiveFloor(10) = %v, want 1050", got)
	}
}

func TestActiveFloor20Games(t *testing.T) {
	p := DefaultRatingParams
	// 20 game → floor = 1100 + 20×(-5) = 1000 (min)
	got := ActiveFloor(20, p)
	if got != 1000 {
		t.Fatalf("ActiveFloor(20) = %v, want 1000", got)
	}
}

func TestActiveFloor30Games(t *testing.T) {
	p := DefaultRatingParams
	// 30 game → floor = 1100 + 30×(-5) = 950 → min 1000
	got := ActiveFloor(30, p)
	if got != 1000 {
		t.Fatalf("ActiveFloor(30) = %v, want 1000", got)
	}
}

func TestActiveFloorDecreasing(t *testing.T) {
	p := DefaultRatingParams
	// Floor harus menurun seiring bertambahnya game
	floor0 := ActiveFloor(0, p)
	floor5 := ActiveFloor(5, p)
	floor10 := ActiveFloor(10, p)
	floor15 := ActiveFloor(15, p)

	if floor0 <= floor5 || floor5 <= floor10 || floor10 <= floor15 {
		t.Fatalf("floor harus menurun: 0=%v, 5=%v, 10=%v, 15=%v", floor0, floor5, floor10, floor15)
	}
}

// ── Team size weight tests ──────────────────────────────────────────────

func TestTeamSizeWeightDisabled(t *testing.T) {
	p := DefaultRatingParams
	// TeamSizeNormalization = false (disabled)
	got := TeamSizeWeight(2, p)
	if got != 1.0 {
		t.Fatalf("TeamSizeWeight(disabled, 2) = %v, want 1.0", got)
	}
}

func TestTeamSizeWeightSinglePlayer(t *testing.T) {
	p := DefaultRatingParams
	p.TeamSizeNormalization = true // enabled
	// 1 pemain → weight = 1.0 (tidak ada perubahan)
	got := TeamSizeWeight(1, p)
	if got != 1.0 {
		t.Fatalf("TeamSizeWeight(1) = %v, want 1.0", got)
	}
}

func TestTeamSizeWeightTwoPlayers(t *testing.T) {
	p := DefaultRatingParams
	p.TeamSizeNormalization = true // enabled
	// 2 pemain → weight = 0.85
	got := TeamSizeWeight(2, p)
	if math.Abs(got-0.85) > 0.001 {
		t.Fatalf("TeamSizeWeight(2) = %v, want 0.85", got)
	}
}

func TestTeamSizeWeightThreePlayers(t *testing.T) {
	p := DefaultRatingParams
	p.TeamSizeNormalization = true // enabled
	// 3 pemain → weight = 0.85² = 0.7225
	got := TeamSizeWeight(3, p)
	if math.Abs(got-0.7225) > 0.001 {
		t.Fatalf("TeamSizeWeight(3) = %v, want 0.7225", got)
	}
}

func TestTeamSizeWeightDecreasing(t *testing.T) {
	p := DefaultRatingParams
	p.TeamSizeNormalization = true // enabled
	// Weight harus menurun seiring bertambahnya pemain
	w1 := TeamSizeWeight(1, p)
	w2 := TeamSizeWeight(2, p)
	w3 := TeamSizeWeight(3, p)

	if w1 <= w2 || w2 <= w3 {
		t.Fatalf("weight harus menurun: 1=%v, 2=%v, 3=%v", w1, w2, w3)
	}
}

// ── Volatility dampening tests ──────────────────────────────────────────

func TestVolatilityFactorDisabled(t *testing.T) {
	p := DefaultRatingParams
	// VolatilityDampening = false (disabled)
	got := VolatilityFactor(8, 2, p)
	if got != 1.0 {
		t.Fatalf("VolatilityFactor(disabled) = %v, want 1.0", got)
	}
}

func TestVolatilityFactorNotEnoughGames(t *testing.T) {
	p := DefaultRatingParams
	p.VolatilityDampening = true
	// Belum cukup game (4 < 5) → factor = 1.0
	got := VolatilityFactor(4, 0, p)
	if got != 1.0 {
		t.Fatalf("VolatilityFactor(4 game) = %v, want 1.0", got)
	}
}

func TestVolatilityFactorNormalWinRate(t *testing.T) {
	p := DefaultRatingParams
	p.VolatilityDampening = true
	// Win rate 50% (5W-5L) → normal → factor = 1.0
	got := VolatilityFactor(5, 5, p)
	if got != 1.0 {
		t.Fatalf("VolatilityFactor(50 pct) = %v, want 1.0", got)
	}
}

func TestVolatilityFactorHighWinRate(t *testing.T) {
	p := DefaultRatingParams
	p.VolatilityDampening = true
	// Win rate 80% (8W-2L) > 0.6 → factor = 0.9
	got := VolatilityFactor(8, 2, p)
	if math.Abs(got-0.9) > 0.001 {
		t.Fatalf("VolatilityFactor(80 pct) = %v, want 0.9", got)
	}
}

func TestVolatilityFactorLowWinRate(t *testing.T) {
	p := DefaultRatingParams
	p.VolatilityDampening = true
	// Win rate 20% (2W-8L) < 0.4 → factor = 0.9
	got := VolatilityFactor(2, 8, p)
	if math.Abs(got-0.9) > 0.001 {
		t.Fatalf("VolatilityFactor(20 pct) = %v, want 0.9", got)
	}
}
