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
	// SessionTierInit — mapping tier session (1-4) → kelas awal + rating awal.
	SessionTierInit map[string]TierInit
	// ClassBands — band 12 sub-tier (D-..A+): kelas → [min, max) (nilai nil = unbounded).
	ClassBands map[string][2]*float64
}

// TierInit — baseline forming dari tier session.
type TierInit struct {
	Class  string  `json:"class"`
	Rating float64 `json:"rating"`
}

// DefaultRatingConfig — fallback bila config tidak ada/invalid.
var DefaultRatingConfig = RatingConfig{
	Params: DefaultRatingParams,
	PhaseWeights: map[string]float64{
		"group": 1.0, "qf": 1.05, "sf": 1.15, "3rd": 1.0, "final": 1.25, "regular": 1.0,
	},
	IngestLockedOnly:   true,
	AutoReconcile:      false,
	AbsentPolicy:       AbsentSkipGame,
	PlaceholderPolicy:  PlaceholderRateAsUnknown,
	DecayEnabled:       false,
	DecayThresholdDays: 60,
	DecayPerWeek:       5.0,
	DecayFloor:         1000,
	SeasonStart:        "2026-05-23",
	SessionTierInit: map[string]TierInit{
		"1": {Class: "A", Rating: 2050},
		"2": {Class: "B", Rating: 1750},
		"3": {Class: "C", Rating: 1450},
		"4": {Class: "D", Rating: 1150},
	},
	ClassBands: map[string][2]*float64{
		"D-": {nil, fptr(1099)}, "D": {fptr(1100), fptr(1199)}, "D+": {fptr(1200), fptr(1299)},
		"C-": {fptr(1300), fptr(1399)}, "C": {fptr(1400), fptr(1499)}, "C+": {fptr(1500), fptr(1599)},
		"B-": {fptr(1600), fptr(1699)}, "B": {fptr(1700), fptr(1799)}, "B+": {fptr(1800), fptr(1899)},
		"A-": {fptr(1900), fptr(1999)}, "A": {fptr(2000), fptr(2099)}, "A+": {fptr(2100), nil},
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
	if len(c.SessionTierInit) != 4 {
		return fmt.Errorf("rating_config: session_tier_init harus memuat tier 1-4")
	}
	for tier, init := range c.SessionTierInit {
		if !ValidClass(init.Class) || init.Rating <= 0 {
			return fmt.Errorf("rating_config: session_tier_init[%s] invalid (class %q rating %.0f)", tier, init.Class, init.Rating)
		}
	}
	if len(c.ClassBands) != 12 {
		return fmt.Errorf("rating_config: class_bands harus memuat 12 sub-tier")
	}
	for cls, band := range c.ClassBands {
		if !ValidClass(cls) {
			return fmt.Errorf("rating_config: class_bands key %q tidak valid", cls)
		}
		if band[0] != nil && band[1] != nil && *band[0] >= *band[1] {
			return fmt.Errorf("rating_config: class_bands[%s] min>=max", cls)
		}
	}
	return nil
}

// ValidClass — 12 sub-tier valid (D-..A+).
func ValidClass(cls string) bool {
	switch cls {
	case "D-", "D", "D+", "C-", "C", "C+", "B-", "B", "B+", "A-", "A", "A+":
		return true
	}
	return false
}

// ClassForRating — kelas derived dari rating (12 band, config-driven).
func (c *RatingConfig) ClassForRating(r float64) string {
	best := "D-"
	for cls, band := range c.ClassBands {
		lo, hi := band[0], band[1]
		if lo != nil && r < *lo {
			continue
		}
		if hi != nil && r > *hi {
			continue
		}
		best = cls
		break
	}
	return best
}

// FloorOf — floor kelas: sub-tier minus huruf (C → C-). A+ → A+.
func FloorOf(class string) string {
	if class == "" || !ValidClass(class) {
		return class
	}
	switch class {
	case "D+", "D", "D-":
		return "D-"
	case "C+", "C", "C-":
		return "C-"
	case "B+", "B", "B-":
		return "B-"
	case "A+", "A", "A-":
		return "A-"
	}
	return class
}

// DisplayClass — max(derived, floor) — kelas yang ditampilkan.
func (c *RatingConfig) DisplayClass(rating float64, assigned string) string {
	derived := c.ClassForRating(rating)
	if assigned == "" {
		return derived
	}
	floor := FloorOf(assigned)
	if classOrder(derived) < classOrder(floor) {
		return floor
	}
	return derived
}

// classOrder — urutan 12 sub-tier untuk perbandingan (D- = 1 .. A+ = 12).
func classOrder(cls string) int {
	order := []string{"D-", "D", "D+", "C-", "C", "C+", "B-", "B", "B+", "A-", "A", "A+"}
	for i, c := range order {
		if c == cls {
			return i + 1
		}
	}
	return 0
}

// MidRatingForClass — rating tengah sebuah sub-band: (lo+hi)/2; band tanpa
// batas pakai offset 50 dari batas yang ada. Basis "reset ke mid kelas".
func (c *RatingConfig) MidRatingForClass(cls string) (float64, bool) {
	band, ok := c.ClassBands[cls]
	if !ok {
		return 0, false
	}
	lo, hi := band[0], band[1]
	switch {
	case lo != nil && hi != nil:
		// round → mid BERSIH (1450 utk C [1400,1499]) — konsisten dengan session_tier_init
		return math.Round((*lo + *hi) / 2), true
	case lo != nil:
		return *lo + 50, true // A+ (atas)
	case hi != nil:
		return *hi - 50, true // D- (bawah)
	default:
		return 0, false
	}
}

// FormingForTier — forming kelas + rating awal dari tier induk (letter A-D).
// Tier session (1-4) dipetakan ke letter, lalu SessionTierInit.
func (c *RatingConfig) FormingForTier(tierLetter string) (TierInit, bool) {
	key := map[string]string{"A": "1", "B": "2", "C": "3", "D": "4"}[tierLetter]
	init, ok := c.SessionTierInit[key]
	return init, ok
}
