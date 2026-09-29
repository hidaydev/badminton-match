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

	if err := apply("ingest_locked_only", func(v json.RawMessage) error { return asBool("ingest_locked_only", &cfg.IngestLockedOnly) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("auto_reconcile", func(v json.RawMessage) error { return asBool("auto_reconcile", &cfg.AutoReconcile) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("absent_policy", func(v json.RawMessage) error { return asString("absent_policy", (*string)(&cfg.AbsentPolicy)) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("placeholder_promote_games", func(v json.RawMessage) error { return asInt("placeholder_promote_games", &cfg.PlaceholderPromoteGames) }); err != nil {
		return domain.RatingConfig{}, err
	}
	// ── Ranking poin (§4.8) ──
	if err := apply("rank_window_weeks", func(v json.RawMessage) error { return asInt("rank_window_weeks", &cfg.RankWindowWeeks) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("rank_best_n", func(v json.RawMessage) error { return asInt("rank_best_n", &cfg.RankBestN) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("rank_opponent_weight", func(v json.RawMessage) error { return asBool("rank_opponent_weight", &cfg.RankOpponentWeight) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("rank_session_base", func(v json.RawMessage) error { return f("rank_session_base")(v, &cfg.RankSessionBase) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("rank_thin_evidence_n", func(v json.RawMessage) error { return asInt("rank_thin_evidence_n", &cfg.RankThinEvidenceN) }); err != nil {
		return domain.RatingConfig{}, err
	}
	if err := apply("rank_opponent_clamp", func(v json.RawMessage) error {
		var arr []float64
		if err := json.Unmarshal(v, &arr); err != nil {
			return fmt.Errorf("rating_config: rank_opponent_clamp harus array 2 angka: %w", err)
		}
		if len(arr) != 2 {
			return fmt.Errorf("rating_config: rank_opponent_clamp harus 2 elemen, dapat %d", len(arr))
		}
		cfg.RankOpponentClamp = [2]float64{arr[0], arr[1]}
		return nil
	}); err != nil {
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
