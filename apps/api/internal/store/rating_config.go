package store

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"majadu-api/internal/domain"
)

// ── rating_config loader ──────────────────────────────────────────────────
// Baca semua key dari tabel rating_config (jsonb per key) → domain.RatingConfig
// (validasi range via Validate). Fail-fast di prod; default jika tabel kosong.

// LoadRatingConfig — baca + validasi config rating. `failFast` diisi dari
// cfg.Env == "prod" (error config = stop). Non-prod: default bila salah.
func (s *SessionStore) LoadRatingConfig(ctx context.Context, failFast bool) (domain.RatingConfig, error) {
	cfg := domain.DefaultRatingConfig

	rows, err := s.pool.Query(ctx,
		`SELECT key, value FROM `+s.schema+`.rating_config ORDER BY key`)
	if err != nil {
		if strings.Contains(err.Error(), "does not exist") {
			return cfg, nil // tabel belum ada (pra-migrasi) → default
		}
		return domain.RatingConfig{}, err
	}
	defer rows.Close()

	raw := map[string]json.RawMessage{}
	for rows.Next() {
		var k string
		var v json.RawMessage
		if err := rows.Scan(&k, &v); err != nil {
			return domain.RatingConfig{}, err
		}
		raw[k] = v
	}
	if err := rows.Err(); err != nil {
		return domain.RatingConfig{}, err
	}

	apply := func(key string, fn func(v json.RawMessage) error) error {
		v, ok := raw[key]
		if !ok {
			return nil
		}
		return fn(v)
	}
	// helper float dengan nama key (untuk pesan error)
	f := func(key string) func(v json.RawMessage, out *float64) error {
		return func(v json.RawMessage, out *float64) error {
			var fv float64
			if err := json.Unmarshal(v, &fv); err != nil {
				return fmt.Errorf("rating_config.%s: %w", key, err)
			}
			*out = fv
			return nil
		}
	}
	asInt := func(key string, out *int) error {
		v, ok := raw[key]
		if !ok {
			return nil
		}
		var i int
		if err := json.Unmarshal(v, &i); err != nil {
			return fmt.Errorf("rating_config.%s: %w", key, err)
		}
		*out = i
		return nil
	}
	asBool := func(key string, out *bool) error {
		v, ok := raw[key]
		if !ok {
			return nil
		}
		var b bool
		if err := json.Unmarshal(v, &b); err != nil {
			return fmt.Errorf("rating_config.%s: %w", key, err)
		}
		*out = b
		return nil
	}
	asString := func(key string, out *string) error {
		v, ok := raw[key]
		if !ok {
			return nil
		}
		var s string
		if err := json.Unmarshal(v, &s); err != nil {
			return fmt.Errorf("rating_config.%s: %w", key, err)
		}
		*out = s
		return nil
	}

	if err := apply("initial_rating", func(v json.RawMessage) error { return f("initial_rating")(v, &cfg.Params.InitialRating) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("initial_rd", func(v json.RawMessage) error { return f("initial_rd")(v, &cfg.Params.InitialRD) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("rd_min", func(v json.RawMessage) error { return f("rd_min")(v, &cfg.Params.RDMin) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("rd_max", func(v json.RawMessage) error { return f("rd_max")(v, &cfg.Params.RDMax) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("rd_growth_per_day", func(v json.RawMessage) error { return f("rd_growth_per_day")(v, &cfg.Params.RDGrowthPerDay) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("rating_min", func(v json.RawMessage) error { return f("rating_min")(v, &cfg.Params.RatingMin) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("rating_max", func(v json.RawMessage) error { return f("rating_max")(v, &cfg.Params.RatingMax) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("max_delta_per_game", func(v json.RawMessage) error { return f("max_delta_per_game")(v, &cfg.Params.MaxDelta) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("movm_scale", func(v json.RawMessage) error { return f("movm_scale")(v, &cfg.Params.MovmScale) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("movm_cap", func(v json.RawMessage) error { return f("movm_cap")(v, &cfg.Params.MovmCap) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("phase_weights", func(v json.RawMessage) error {
		var m map[string]float64
		if err := json.Unmarshal(v, &m); err != nil {
			return fmt.Errorf("rating_config.phase_weights: %w", err)
		}
		cfg.PhaseWeights = m
		return nil
	}); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("ingest_locked_only", func(v json.RawMessage) error { return asBool("ingest_locked_only", &cfg.IngestLockedOnly) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("auto_reconcile", func(v json.RawMessage) error { return asBool("auto_reconcile", &cfg.AutoReconcile) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("absent_policy", func(v json.RawMessage) error { return asString("absent_policy", (*string)(&cfg.AbsentPolicy)) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("placeholder_policy", func(v json.RawMessage) error {
		return asString("placeholder_policy", (*string)(&cfg.PlaceholderPolicy))
	}); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("decay_enabled", func(v json.RawMessage) error { return asBool("decay_enabled", &cfg.DecayEnabled) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("decay_threshold_days", func(v json.RawMessage) error { return asInt("decay_threshold_days", &cfg.DecayThresholdDays) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("decay_per_week", func(v json.RawMessage) error { return f("decay_per_week")(v, &cfg.DecayPerWeek) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("decay_floor", func(v json.RawMessage) error { return f("decay_floor")(v, &cfg.DecayFloor) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("season_start", func(v json.RawMessage) error {
		return asString("season_start", &cfg.SeasonStart)
	}); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("session_tier_init", func(v json.RawMessage) error {
		var m map[string]domain.TierInit
		if err := json.Unmarshal(v, &m); err != nil {
			return fmt.Errorf("rating_config.session_tier_init: %w", err)
		}
		cfg.SessionTierInit = m
		return nil
	}); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("class_bands", func(v json.RawMessage) error {
		var raw map[string][2]*float64
		if err := json.Unmarshal(v, &raw); err != nil {
			return fmt.Errorf("rating_config.class_bands: %w", err)
		}
		cfg.ClassBands = raw
		return nil
	}); err != nil {
		return domain.RatingConfig{}, err
	}

	if err := cfg.Validate(); err != nil {
		if failFast {
			return domain.RatingConfig{}, err
		}
		return domain.DefaultRatingConfig, nil // non-prod: fallback default
	}
	return cfg, nil
}
