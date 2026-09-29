package domain

import (
	"fmt"
	"math"
)

// ── RatingConfig — parameter + policy rating (RATING_ENGINE_DESIGN.md §5.5).
// Disimpan di tabel rating_config (jsonb per key); loader (store) membaca →
// validasi → domain.RatingConfig. Fail-fast di prod (config.Config.Env).

type AbsentPolicy string

const (
	AbsentSkipGame   AbsentPolicy = "skip_game"
	AbsentSkipPlayer AbsentPolicy = "skip_player"
	AbsentCount      AbsentPolicy = "count"
)

type RatingConfig struct {
	// Params (RatingParams) dihapus 2026-09-29 bersama pensiun Glicko —
	// tidak ada lagi perhitungan rating yang memakai parameter numeriknya.
	PhaseWeights     map[string]float64
	IngestLockedOnly bool
	AutoReconcile    bool
	AbsentPolicy     AbsentPolicy
	// SeasonStart — awal musim (RATING_TIERING_REVAMP §2.5.7). Match < season_start
	// tidak dihitung rating. Format yyyy-mm-dd.
	SeasonStart string
	// SessionTierInit — baseline forming per tier (8-tier: D..A+).
	// Key = tier itu sendiri (single source — TIER_8_UNIFICATION.md §3.4).
	SessionTierInit map[string]TierInit
	// ClassBands — band 8-tier (D..A+): tier → [min, max] (nilai nil = unbounded).
	ClassBands map[string][2]*float64

	// PlaceholderPromoteGames — jumlah game minimal sebelum placeholder
	// dianggap "real player" dan mendapat rating normal (bukan sintetik).
	// 0 = disabled (placeholder selalu rate_as_unknown).
	PlaceholderPromoteGames int

	// ── Ranking poin (papan publik ala BWF) ──────────────────────────────
	// Lihat RANKING_POIN_BWF_RANCANGAN.md §4.8. Poin dihitung saat baca.
	RankWindowWeeks    int        // window bergulir; entri lebih tua diabaikan
	RankBestN          int        // ambil N entri terbaik dalam window
	RankOpponentWeight bool       // pakai pengali kekuatan lawan
	RankOpponentClamp  [2]float64 // penjepit pengali [min, max]
	RankSessionBase    float64    // nilai dasar game sesi
	RankThinEvidenceN  int        // entri < N → tandai "bukti tipis"
}

// TierInit — baseline forming dari tier.
type TierInit struct {
	Class  string  `json:"class"`
	Rating float64 `json:"rating"`
}

// DefaultRatingConfig — fallback bila config tidak ada/invalid.
// AbsentPolicy default = skip_player (kontrak produk: game tetap jalan,
// absent player tidak dapat delta — 3 player lain tetap dapat delta).
var DefaultRatingConfig = RatingConfig{
	PhaseWeights: map[string]float64{
		"group": 1.0, "qf": 1.05, "sf": 1.15, "3rd": 1.0, "final": 1.25, "regular": 1.0,
	},
	IngestLockedOnly:        true,
	AutoReconcile:           false,
	AbsentPolicy:            AbsentSkipPlayer,
	SeasonStart:             "2026-05-23",
	PlaceholderPromoteGames: 10, // setelah 10 game, placeholder dianggap real player

	// Ranking poin — nilai awal mengikuti RANKING_POIN_BWF_RANCANGAN.md §4.8.
	RankWindowWeeks:    12,
	RankBestN:          10,
	RankOpponentWeight: true,
	RankOpponentClamp:  [2]float64{0.5, 1.5},
	RankSessionBase:    250,
	RankThinEvidenceN:  3,
	SessionTierInit: map[string]TierInit{
		"D":  {Class: "D", Rating: 1150},
		"D+": {Class: "D+", Rating: 1250},
		"C":  {Class: "C", Rating: 1450},
		"C+": {Class: "C+", Rating: 1550},
		"B":  {Class: "B", Rating: 1750},
		"B+": {Class: "B+", Rating: 1850},
		"A":  {Class: "A", Rating: 2050},
		"A+": {Class: "A+", Rating: 2150},
	},
	// Collapse 12→8 mempertahankan grid 100: D = D-∪D (≤1199), dst.
	ClassBands: map[string][2]*float64{
		"D": {fptr(1000), fptr(1199)}, "D+": {fptr(1200), fptr(1299)},
		"C": {fptr(1300), fptr(1499)}, "C+": {fptr(1500), fptr(1599)},
		"B": {fptr(1600), fptr(1799)}, "B+": {fptr(1800), fptr(1899)},
		"A": {fptr(1900), fptr(2099)}, "A+": {fptr(2100), nil},
	},
}

func fptr(v float64) *float64 { return &v }

// Validate — validasi range/semantik (fail-fast). Error menyebut key yang
// bermasalah.
//
// Validasi parameter rating Glicko (initial_rating, rd_min/max, movm, gap_cap,
// dynamic cap, active floor, team size, volatility, decay) DIHAPUS 2026-09-29
// bersama pensiun Glicko: parameternya tidak lagi dibaca siapa pun, jadi
// memvalidasinya hanya menambah jalur gagal yang tidak bermakna.
func (c *RatingConfig) Validate() error {
	if len(c.PhaseWeights) == 0 {
		return fmt.Errorf("rating_config: phase_weights must not be empty")
	}
	for phase, w := range c.PhaseWeights {
		if w <= 0 {
			return fmt.Errorf("rating_config: phase_weights[%q] = %v, harus > 0", phase, w)
		}
	}
	switch c.AbsentPolicy {
	case AbsentSkipGame, AbsentSkipPlayer, AbsentCount:
	default:
		return fmt.Errorf("rating_config: absent_policy %q tidak dikenal", c.AbsentPolicy)
	}
	if c.PlaceholderPromoteGames < 0 {
		return fmt.Errorf("rating_config: placeholder_promote_games must be ≥ 0")
	}
	if c.SeasonStart == "" {
		return fmt.Errorf("rating_config: season_start must not be empty")
	}
	if len(c.SessionTierInit) != 8 {
		return fmt.Errorf("rating_config: session_tier_init harus memuat 8 tier (D..A+)")
	}
	for tier, init := range c.SessionTierInit {
		if !ValidTier(tier) || !ValidTier(init.Class) || init.Rating <= 0 {
			return fmt.Errorf("rating_config: session_tier_init[%s] invalid (class %q rating %.0f)", tier, init.Class, init.Rating)
		}
	}
	if len(c.ClassBands) != 8 {
		return fmt.Errorf("rating_config: class_bands harus memuat 8 tier")
	}
	for cls, band := range c.ClassBands {
		if !ValidTier(cls) {
			return fmt.Errorf("rating_config: class_bands key %q tidak valid", cls)
		}
		if band[0] != nil && band[1] != nil && *band[0] >= *band[1] {
			return fmt.Errorf("rating_config: class_bands[%s] min>=max", cls)
		}
	}
	return nil
}

// ValidTier — 8 tier valid (D..A+).
func ValidTier(tier string) bool {
	switch tier {
	case "D", "D+", "C", "C+", "B", "B+", "A", "A+":
		return true
	}
	return false
}

// TierForRating — tier derived dari rating (8 band, config-driven).
// Band diperlakukan half-open: pilih band dengan batas bawah terbesar yang
// <= r. Ini menutup sela antar boundary integer (mis. B+ 1800-1899 vs
// A 1900-2099 untuk r=1899.23) yang dulu jatuh ke default "D".
func (c *RatingConfig) TierForRating(r float64) string {
	best := "D"
	bestLo := math.Inf(-1)
	for tier, band := range c.ClassBands {
		lo := band[0]
		if lo == nil {
			// Band tanpa batas bawah → kandidat terendah; dipakai hanya
			// kalau r di bawah semua batas bawah band lain.
			if math.IsInf(bestLo, -1) {
				best = tier
			}
			continue
		}
		if r < *lo || *lo <= bestLo {
			continue
		}
		bestLo = *lo
		best = tier
	}
	return best
}

// MidRatingForTier — baseline rating sebuah tier: nilai forming dari
// session_tier_init (konsisten di ingest/rebuild/rebaseline/reset), fallback
// mid band. Basis "reset ke mid tier".
func (c *RatingConfig) MidRatingForTier(tier string) (float64, bool) {
	if init, ok := c.SessionTierInit[tier]; ok {
		return init.Rating, true
	}
	band, ok := c.ClassBands[tier]
	if !ok {
		return 0, false
	}
	lo, hi := band[0], band[1]
	switch {
	case lo != nil && hi != nil:
		return math.Round((*lo + *hi) / 2), true
	case lo != nil:
		return *lo + 50, true // A+ (atas)
	case hi != nil:
		return *hi - 50, true // D (bawah)
	default:
		return 0, false
	}
}

// FormingForTier — forming baseline dari tier induk (key = tier itu sendiri).
func (c *RatingConfig) FormingForTier(tier string) (TierInit, bool) {
	init, ok := c.SessionTierInit[tier]
	return init, ok
}
