package domain

import "fmt"

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
}

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
	return nil
}
