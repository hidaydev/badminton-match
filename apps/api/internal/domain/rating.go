package domain

import "math"

// ── Rating engine — Glicko-1-lite (online) ────────────────────────────────
// RATING_ENGINE_DESIGN.md §3 (Rev 3.1).
// Fungsi MURNI — tanpa IO; satu-satunya sumber kebenaran perhitungan.
// Replay/full-rebuild harus memanggil fungsi yang sama persis.

// RatingParams — parameter numerik rating (subset rating_config, seed di
// migration 000008). Semua validasi range dilakukan loader (store).
type RatingParams struct {
	InitialRating  float64
	InitialRD      float64
	RDMin          float64
	RDMax          float64
	RDGrowthPerDay float64
	RatingMin      float64
	RatingMax      float64
	MaxDelta       float64
	MovmScale      float64
	MovmCap        float64
}

// DefaultRatingParams — fallback bila config tidak ada/invalid.
var DefaultRatingParams = RatingParams{
	InitialRating:  1250, // forming berbasis tier menyusul (T3) — flat fallback
	InitialRD:      220,  // T2 rekalibrasi: pemain baru mulai provisional, konvergen lebih cepat
	RDMin:          30,
	RDMax:          350,
	RDGrowthPerDay: 3, // T2: growth mingguan ~9 (bukan 105) → steady-state rd ~55-65
	RatingMin:      1000,
	RatingMax:      2500,
	MaxDelta:       30, // T2: 2.5-3x typical win (10-12) → 1 match ≤ 0.3 band
	MovmScale:      0.5,
	MovmCap:        2.0,
}

// RatingState — rating + deviation seorang pemain.
type RatingState struct {
	Rating float64
	RD     float64
}

// RatingOpponent — lawan (rating + rd) yang ikut dihitung expected.
type RatingOpponent struct {
	Rating float64
	RD     float64
}

// RatingOutcome — hasil per pemain: 1 menang, 0 kalah, 0.5 seri (tidak
// terjadi di badminton — disediakan untuk kompatibilitas).
const (
	OutcomeWin  = 1.0
	OutcomeLoss = 0.0
	OutcomeDraw = 0.5
)

func ratingQ() float64 { return math.Log(10) / 400 }

// G — faktor pembobot RD lawan: g(rd) = 1/sqrt(1+3q²rd²/π²).
func G(rd float64) float64 {
	q := ratingQ()
	return 1 / math.Sqrt(1+3*q*q*rd*rd/(math.Pi*math.Pi))
}

// ExpectedScore — expected vs satu lawan: 1/(1+10^(−g(rd_j)(r−r_j)/400)).
func ExpectedScore(r float64, opp RatingOpponent) float64 {
	return 1 / (1 + math.Pow(10, -G(opp.RD)*(r-opp.Rating)/400))
}

// MarginOfVictory — MoVM ternormalisasi: m = margin/target;
// MoVM = min(movm_cap, movm_scale + m). Design §3.4.
func MarginOfVictory(scoreA, scoreB, target int, p RatingParams) float64 {
	delta := math.Abs(float64(scoreA - scoreB))
	m := delta / float64(target)
	movm := p.MovmScale + m
	if movm > p.MovmCap {
		movm = p.MovmCap
	}
	return movm
}

// GrowRD — pertumbuhan uncertainty per hari idle (basis tanggal sumber,
// bukan wall-clock): rd' = min(rd_max, sqrt(rd² + (c·hari)²)). §3.6.
func GrowRD(rd float64, idleDays int, p RatingParams) float64 {
	if idleDays <= 0 {
		return rd
	}
	c := p.RDGrowthPerDay * float64(idleDays)
	next := math.Sqrt(rd*rd + c*c)
	if next < rd {
		return rd
	}
	if next > p.RDMax {
		next = p.RDMax
	}
	return next
}

// round2 — pembulatan ke 2 desimal (rating/delta) — satu code path.
func round2(v float64) float64 { return math.Round(v*100) / 100 }

// round4 — pembulatan ke 4 desimal (expected/movm) — satu code path.
func round4(v float64) float64 { return math.Round(v*10000) / 10000 }

// Round2 / Round4 — ekspor publik (dipakai store layer untuk penyimpanan
// dengan code path pembulatan yang SAMA dengan kalkulasi asli — §3.7).
func Round2(v float64) float64 { return round2(v) }
func Round4(v float64) float64 { return round4(v) }

// TierForRating — tier D..S+ dari band rating (design §7). 1=D .. 10=S+.
// Badge provisional = rd > 200 (keputusan display, bukan fungsi ini).
func TierForRating(r float64) int {
	switch {
	case r >= 1800:
		return 10
	case r >= 1700:
		return 9
	case r >= 1600:
		return 8
	case r >= 1500:
		return 7
	case r >= 1400:
		return 6
	case r >= 1300:
		return 5
	case r >= 1200:
		return 4
	case r >= 1100:
		return 3
	case r >= 1050:
		return 2
	default:
		return 1
	}
}

// Provisional — RD > 200 → rating belum stabil (badge di UI).
func Provisional(rd float64) bool { return rd > 200 }

// GlickoUpdate — update satu pemain melawan daftar lawan (1–2 untuk ganda;
// 1 untuk singles/positional). MoVM·w mengalikan SELURUH update (simetris,
// §3.2). Delta di-cap max_delta_per_game; rating di-clamp [rating_min,max];
// RD di-clamp [rd_min,rd_max].
//
// Mengembalikan state baru + delta (sudah round2). Wajib dipakai persis
// sama oleh kalkulasi asli DAN full rebuild (reproducibility).
func GlickoUpdate(st RatingState, opps []RatingOpponent, outcome float64, movm, phaseWeight float64, p RatingParams) (RatingState, float64) {
	q := ratingQ()
	var gSum, dSum float64
	for _, o := range opps {
		g := G(o.RD)
		e := ExpectedScore(st.Rating, o)
		gSum += g * (outcome - e)
		dSum += g * g * e * (1 - e)
	}
	var dSq float64
	if dSum > 0 {
		dSq = 1 / (q * q * dSum)
	}
	factor := q / (1/(st.RD*st.RD) + 1/dSq)
	delta := factor * gSum * movm * phaseWeight

	// Cap delta per game (§3.7)
	if delta > p.MaxDelta {
		delta = p.MaxDelta
	}
	if delta < -p.MaxDelta {
		delta = -p.MaxDelta
	}
	delta = round2(delta)

	newRating := st.Rating + delta
	if newRating > p.RatingMax {
		newRating = p.RatingMax
	}
	if newRating < p.RatingMin {
		newRating = p.RatingMin
	}
	newRating = round2(newRating)

	var newRD float64
	if dSq > 0 {
		newRD = math.Sqrt(1 / (1/(st.RD*st.RD) + 1/dSq))
	} else {
		newRD = st.RD
	}
	if newRD < p.RDMin {
		newRD = p.RDMin
	}
	if newRD > p.RDMax {
		newRD = p.RDMax
	}
	newRD = round2(newRD)

	return RatingState{Rating: newRating, RD: newRD}, delta
}
