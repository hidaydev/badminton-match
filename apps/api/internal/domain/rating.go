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

	// Anti-sandbagging: gap-based cap.
	// Jika rating gap antara pemain dan rata-rata lawan > GapCapThreshold,
	// maka effective cap dikurangi proporsional.
	GapCapThreshold float64 // gap minimal untuk aktivasi (0 = disabled)
	GapCapSlope     float64 // gap slope: reduction = (gap - threshold) / slope

	// Dynamic cap berdasarkan RD:
	// - RD > 200 (provisional): cap lebih longgar (multiplier)
	// - RD < 50 (established): cap lebih ketat (multiplier)
	ProvisionalCapMult float64 // multiplier untuk RD > 200 (misal: 1.5)
	EstablishedCapMult float64 // multiplier untuk RD < 50 (misal: 0.8)
	RDProvisional      float64 // threshold RD untuk provisional (misal: 200)
	RDEstablished      float64 // threshold RD untuk established (misal: 50)

	// Active floor: floor dinamis berdasarkan jumlah game.
	// Pemain baru (0 game) mendapat floor lebih tinggi.
	// Pemain yang sudah main banyak game mendapat floor lebih rendah.
	ActiveFloorBase    float64 // floor dasar untuk pemain 0 game (misal: 1100)
	ActiveFloorPerGame float64 // penurunan per game (misal: -5, jadi 10 game → 1100-50=1050)
	ActiveFloorMin     float64 // floor minimum (misal: 1000)

	// Team size normalization: kompensasi untuk tim dengan jumlah pemain
	// berbeda (absent skip_player). Tim dengan lebih banyak pemain mendapat
	// delta lebih kecil (karena advantage jumlah).
	TeamSizeNormalization bool    // aktifkan normalisasi
	TeamSizeWeightFactor  float64 // faktor penurunan per pemain tambahan (misal: 0.85)

	// Consistency dampening (Glicko-2 lite): kurangi delta untuk pemain
	// dengan win rate ekstrem (> threshold atau < 1-threshold).
	// Pemain yang sangat menang/kalah mendapat update lebih kecil.
	VolatilityDampening  bool    // aktifkan dampening
	VolatilityThreshold  float64 // win rate threshold (misal: 0.6 → >0.6 atau <0.4 kena dampening)
	VolatilityFactor     float64 // faktor penurunan (misal: 0.9 → delta × 0.9)
	MinGamesForDampening int     // minimal game sebelum dampening aktif (misal: 5)
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

	// Anti-sandbagging: gap > 500 → cap dikurangi proporsional.
	// Gap 700 → effective cap = 30 × (1 - 200/1000) = 24
	// Gap 1000 → effective cap = 30 × 0.5 = 15
	// Gap 1500 → effective cap = 30 × 0.3 = 9 (min 5)
	GapCapThreshold: 500,
	GapCapSlope:     1000,

	// Dynamic cap berdasarkan RD:
	// - Provisional (RD > 200): cap 1.5x → pemain baru bisa stabilisasi lebih cepat
	// - Established (RD < 50): cap 0.8x → pemain stabil mendapat update lebih kecil
	ProvisionalCapMult: 1.5,
	EstablishedCapMult: 0.8,
	RDProvisional:      200,
	RDEstablished:      50,

	// Active floor: floor dinamis berdasarkan jumlah game.
	// 0 game → floor 1100, 10 game → 1050, 20 game → 1000 (min)
	ActiveFloorBase:    1100,
	ActiveFloorPerGame: -5,
	ActiveFloorMin:     1000,

	// Team size normalization: kompensasi untuk tim dengan jumlah pemain
	// berbeda (absent skip_player). Disabled by default.
	// Jika diaktifkan: 2 pemain → delta × 0.85, 3 pemain → delta × 0.72
	TeamSizeNormalization: false, // disabled by default
	TeamSizeWeightFactor:  0.85,

	// Consistency dampening (Glicko-2 lite): disabled by default.
	// Jika diaktifkan: win rate > 0.6 atau < 0.4 → delta × 0.9
	VolatilityDampening:  false, // disabled by default
	VolatilityThreshold:  0.6,
	VolatilityFactor:     0.9,
	MinGamesForDampening: 5,
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

// DecayFactor — faktor penurunan rating karena idle.
// rating' = max(rating - weeks × decayPerWeek, floor).
// weeks = idleDays / 7.0. Hanya aktif jika idleDays > threshold.
func DecayFactor(rating float64, idleDays int, p RatingParams, decayEnabled bool, decayThresholdDays int, decayPerWeek, decayFloor float64) float64 {
	if !decayEnabled || idleDays <= decayThresholdDays {
		return rating
	}
	weeks := float64(idleDays) / 7.0
	decay := weeks * decayPerWeek
	newRating := rating - decay
	if newRating < decayFloor {
		newRating = decayFloor
	}
	return round2(newRating)
}

// ActiveFloor — floor dinamis berdasarkan jumlah game.
// Pemain 0 game: floor = base (1100)
// Pemain 10 game: floor = base + 10 × perGame = 1100 - 50 = 1050
// Pemain 20+ game: floor = min (1000)
func ActiveFloor(gamesPlayed int, p RatingParams) float64 {
	floor := p.ActiveFloorBase + (float64(gamesPlayed) * p.ActiveFloorPerGame)
	if floor < p.ActiveFloorMin {
		floor = p.ActiveFloorMin
	}
	return floor
}

// TeamSizeWeight — faktor penurunan delta berdasarkan jumlah pemain di tim.
// Tim 1 pemain: weight = 1.0 (tidak ada perubahan)
// Tim 2 pemain: weight = factor (misal: 0.85)
// Tim 3 pemain: weight = factor² (misal: 0.72)
// Disabled jika TeamSizeNormalization = false.
func TeamSizeWeight(teamSize int, p RatingParams) float64 {
	if !p.TeamSizeNormalization || teamSize <= 1 {
		return 1.0
	}
	return math.Pow(p.TeamSizeWeightFactor, float64(teamSize-1))
}

// VolatilityFactor — faktor penurunan delta berdasarkan konsistensi win rate.
// Win rate ekstrem (> threshold atau < 1-threshold) → factor < 1.0.
// Disabled jika VolatilityDampening = false atau belum cukup game.
func VolatilityFactor(wins, losses int, p RatingParams) float64 {
	if !p.VolatilityDampening || wins+losses < p.MinGamesForDampening {
		return 1.0
	}
	winRate := float64(wins) / float64(wins+losses)
	if winRate > p.VolatilityThreshold || winRate < (1-p.VolatilityThreshold) {
		return p.VolatilityFactor
	}
	return 1.0
}

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

	// Cap delta per game — enhanced dengan gap-aware anti-sandbagging
	// DAN dynamic cap berdasarkan RD pemain.
	effectiveCap := p.MaxDelta

	// Dynamic cap berdasarkan RD pemain
	if p.RDProvisional > 0 && st.RD > p.RDProvisional {
		// Provisional player: cap lebih longgar
		effectiveCap = p.MaxDelta * p.ProvisionalCapMult
	} else if p.RDEstablished > 0 && st.RD < p.RDEstablished {
		// Established player: cap lebih ketat
		effectiveCap = p.MaxDelta * p.EstablishedCapMult
	}

	// Gap cap hanya aktif jika GapCapThreshold > 0, ada lawan, dan slope valid
	if p.GapCapThreshold > 0 && p.GapCapSlope > 0 && len(opps) > 0 {
		var oppAvg float64
		for _, o := range opps {
			oppAvg += o.Rating
		}
		oppAvg /= float64(len(opps))
		gap := math.Abs(st.Rating - oppAvg)
		if gap > p.GapCapThreshold {
			reduction := (gap - p.GapCapThreshold) / p.GapCapSlope
			gapCap := p.MaxDelta * (1.0 - reduction)
			if gapCap < 5 { // minimum cap 5 agar update tetap terjadi
				gapCap = 5
			}
			// Ambil yang lebih kecil antara RD cap dan gap cap
			if gapCap < effectiveCap {
				effectiveCap = gapCap
			}
		}
	}

	if delta > effectiveCap {
		delta = effectiveCap
	}
	if delta < -effectiveCap {
		delta = -effectiveCap
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
