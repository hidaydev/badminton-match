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

type PlaceholderPolicy string

const (
	PlaceholderRateAsUnknown PlaceholderPolicy = "rate_as_unknown"
	PlaceholderSkip          PlaceholderPolicy = "skip"
)

type RatingConfig struct {
	Params             RatingParams
	PhaseWeights       map[string]float64
	IngestLockedOnly   bool
	AutoReconcile      bool
	AbsentPolicy       AbsentPolicy
	PlaceholderPolicy  PlaceholderPolicy
	DecayEnabled       bool
	DecayThresholdDays int
	DecayPerWeek       float64
	DecayFloor         float64
	// SeasonStart — awal musim (RATING_TIERING_REVAMP §2.5.7). Match < season_start
	// tidak masuk rating. Format yyyy-mm-dd.
	SeasonStart string
	// SessionTierInit — baseline forming per tier (8-tier: D..A+).
	// Key = tier itu sendiri (single source — TIER_8_UNIFICATION.md §3.4).
	SessionTierInit map[string]TierInit
	// ClassBands — band 8-tier (D..A+): tier → [min, max] (nilai nil = unbounded).
	ClassBands map[string][2]*float64
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
	Params: DefaultRatingParams,
	PhaseWeights: map[string]float64{
		"group": 1.0, "qf": 1.05, "sf": 1.15, "3rd": 1.0, "final": 1.25, "regular": 1.0,
	},
	IngestLockedOnly:   true,
	AutoReconcile:      false,
	AbsentPolicy:       AbsentSkipPlayer,
	PlaceholderPolicy:  PlaceholderRateAsUnknown,
	DecayEnabled:       false,
	DecayThresholdDays: 60,
	DecayPerWeek:       5.0,
	DecayFloor:         1000,
	SeasonStart:        "2026-05-23",
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
// bermasalah. Invariant penting: rating_min ≤ 1250 ≤ rating_max, rd_min ≤ 350 ≤ rd_max.
func (c *RatingConfig) Validate() error {
	p := c.Params
	if !(p.InitialRating >= p.RatingMin && p.InitialRating <= p.RatingMax) {
		return fmt.Errorf("rating_config: initial_rating (%.0f) di luar [rating_min,rating_max]", p.InitialRating)
	}
	if !(p.InitialRD >= p.RDMin && p.InitialRD <= p.RDMax) {
		return fmt.Errorf("rating_config: initial_rd (%.0f) di luar [rd_min,rd_max]", p.InitialRD)
	}
	if p.RDMin < 1 || p.RDMax < p.RDMin {
		return fmt.Errorf("rating_config: rd_min/rd_max invalid (%.0f/%.0f)", p.RDMin, p.RDMax)
	}
	if p.RDGrowthPerDay < 0 {
		return fmt.Errorf("rating_config: rd_growth_per_day must be ≥ 0 (got %v)", p.RDGrowthPerDay)
	}
	if p.RatingMin >= p.RatingMax {
		return fmt.Errorf("rating_config: rating_min (%.0f) harus < rating_max (%.0f)", p.RatingMin, p.RatingMax)
	}
	if p.MaxDelta <= 0 {
		return fmt.Errorf("rating_config: max_delta_per_game must be > 0 (got %v)", p.MaxDelta)
	}
	if p.MovmCap < p.MovmScale || p.MovmScale < 0 {
		return fmt.Errorf("rating_config: movm_scale (%.2f) / movm_cap (%.2f) invalid", p.MovmScale, p.MovmCap)
	}
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
	switch c.PlaceholderPolicy {
	case PlaceholderRateAsUnknown, PlaceholderSkip:
	default:
		return fmt.Errorf("rating_config: placeholder_policy %q tidak dikenal", c.PlaceholderPolicy)
	}
	if c.DecayThresholdDays <= 0 || c.DecayPerWeek <= 0 {
		return fmt.Errorf("rating_config: decay_threshold_days/decay_per_week must be > 0")
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
func (c *RatingConfig) TierForRating(r float64) string {
	best := "D"
	for tier, band := range c.ClassBands {
		lo, hi := band[0], band[1]
		if lo != nil && r < *lo {
			continue
		}
		if hi != nil && r > *hi {
			continue
		}
		best = tier
		break
	}
	return best
}

// FloorOf — floor tier: basis huruf (TIER_8_UNIFICATION.md §3.3).
// B+ → B (tidak boleh tampil di bawah B, boleh naik ke A/A+); A+/A → A; dst.
func FloorOf(tier string) string {
	switch tier {
	case "A+", "A":
		return "A"
	case "B+", "B":
		return "B"
	case "C+", "C":
		return "C"
	case "D+", "D":
		return "D"
	}
	return tier
}

// DisplayTier — max(derived, floor) — tier yang ditampilkan.
func (c *RatingConfig) DisplayTier(rating float64, assigned string) string {
	derived := c.TierForRating(rating)
	if assigned == "" {
		return derived
	}
	floor := FloorOf(assigned)
	if tierOrder(derived) < tierOrder(floor) {
		return floor
	}
	return derived
}

// tierOrder — urutan 8 tier untuk perbandingan (D = 1 .. A+ = 8).
func tierOrder(tier string) int {
	order := []string{"D", "D+", "C", "C+", "B", "B+", "A", "A+"}
	for i, c := range order {
		if c == tier {
			return i + 1
		}
	}
	return 0
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
