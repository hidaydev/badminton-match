package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
)

// ── Revert + FULL REBUILD (RATING_ENGINE_DESIGN.md §4.4a) ─────────────────
// Revert = hapus events by source → FULL REBUILD semua rating_players dari
// SEMUA events tersisa (recompute, BUKAN reuse stored delta — transitivity
// melalui lawan). Deterministik: ordering (date, created_at, source_id,
// game_order) + basis waktu tanggal sumber + phase_weight tersimpan.

// RebuildAll — full rebuild SEMUA rating dari semua events (tool tuning
// config: ubah rating_config → RebuildAll → revalidate). Idempotent.
func (s *SessionStore) RebuildAll(ctx context.Context) (int, error) {
	cfg, err := s.LoadRatingConfig(ctx, false)
	if err != nil {
		return 0, err
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`,
		s.schema+":ratings_ingest"); err != nil {
		return 0, err
	}
	n, err := s.rebuildAll(ctx, tx, cfg)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return n, nil
}

// RevertSource — hapus events sebuah source (session/tournament) + full rebuild.
func (s *SessionStore) RevertSource(ctx context.Context, lookup, kind string) (*IngestResult, error) {
	cfg, err := s.LoadRatingConfig(ctx, false)
	if err != nil {
		return nil, err
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`,
		s.schema+":ratings_ingest"); err != nil {
		return nil, err
	}

	// Resolve lookup → source_id (share_code)
	sourceID, err := s.resolveSourceID(ctx, tx, lookup, kind)
	if err != nil {
		return nil, err
	}

	// Idempotent: source tanpa events = no-op sukses (processed 0).
	var count int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM `+s.schema+`.rating_events WHERE source_id = $1`, sourceID).Scan(&count); err != nil {
		return nil, err
	}
	if count == 0 {
		if err := tx.Commit(ctx); err != nil {
			return nil, err
		}
		return &IngestResult{Processed: 0}, nil
	}

	if err := s.deleteSourceEvents(ctx, tx, sourceID); err != nil {
		return nil, err
	}
	// Invalidasi fingerprint — kalau tidak, re-ingest setelah revert dianggap
	// "no-op" (fingerprint lama masih sama). Path '' sudah didukung ingest.
	if _, err := tx.Exec(ctx, `UPDATE `+s.schema+`.rating_sources SET fingerprint = '' WHERE source_id = $1`, sourceID); err != nil {
		return nil, err
	}

	rebuilt, err := s.rebuildAll(ctx, tx, cfg)
	if err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return &IngestResult{Processed: -count, Players: rebuilt}, nil
}

// SetSourceFinalized — upsert rating_sources.finalized (gate ingest tournament).
// Row baru dengan fingerprint ” (belum diingest) — ingest pertama menimpa.
func (s *SessionStore) SetSourceFinalized(ctx context.Context, sourceID string, finalized bool) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `
		INSERT INTO `+s.schema+`.rating_sources
			(source_id, source_kind, fingerprint, finalized, last_ingested_seq, ingested_at)
		VALUES ($1, 'tournament_classic', '', $2, 0, now())
		ON CONFLICT (source_id) DO UPDATE SET finalized = EXCLUDED.finalized`,
		sourceID, finalized); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// resolveSourceID — lookup (share_code/uuid) → source_id.
func (s *SessionStore) resolveSourceID(ctx context.Context, tx pgx.Tx, lookup, kind string) (string, error) {
	if kind == "session" {
		var share string
		err := tx.QueryRow(ctx, `
			SELECT share_code FROM `+s.schema+`.sessions
			WHERE share_code = $1 OR id::text = $1
			ORDER BY (share_code = $1) DESC LIMIT 1`, lookup).Scan(&share)
		if errors.Is(err, pgx.ErrNoRows) {
			return "", fmt.Errorf("%w: %s", ErrSourceNotFound, lookup)
		}
		return share, err
	}
	var share string
	err := tx.QueryRow(ctx, `
		SELECT share_code FROM `+s.schema+`.tournaments
		WHERE share_code = $1 OR id::text = $1
		ORDER BY (share_code = $1) DESC LIMIT 1`, lookup).Scan(&share)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", fmt.Errorf("%w: %s", ErrSourceNotFound, lookup)
	}
	return share, err
}

// rebuildAll — recompute SEMUA rating_players dari events tersisa, urut
// (date, created_at, source_id, game_order). Memakai stored phase_weight &
// target & scores dari rating_events; pemain dari rating_deltas (team).
func (s *SessionStore) rebuildAll(ctx context.Context, tx pgx.Tx, cfg domain.RatingConfig) (int, error) {
	// Tangkap pemain yang pernah ter-rating (untuk reset-to-default) + tier
	// assigned (single source: players.tier — TIER_8_UNIFICATION).
	priorRows, err := tx.Query(ctx, `
		SELECT rp.player_id::text, coalesce(p.tier, '')
		FROM `+s.schema+`.rating_players rp
		LEFT JOIN `+s.schema+`.players p ON p.id = rp.player_id`)
	if err != nil {
		return 0, err
	}
	prior := map[string]bool{}
	priorTier := map[string]string{}
	for priorRows.Next() {
		var id, tier string
		if err := priorRows.Scan(&id, &tier); err != nil {
			priorRows.Close()
			return 0, err
		}
		prior[id] = true
		priorTier[id] = tier
	}
	priorRows.Close()
	if err := priorRows.Err(); err != nil {
		return 0, err
	}

	type evPlayer struct {
		playerID string
		team     string
	}
	type ev struct {
		id, date    string
		scoreA      int
		scoreB      int
		target      int
		phaseWeight float64
		players     []evPlayer
	}

	// Baca events urut global + pemainnya (via rating_deltas — SATU-SATUNYA
	// sumber pemetaan event→pemain). DIBACA DULU sebelum reset, karena
	// rating_deltas akan dihapus.
	rows, err := tx.Query(ctx, `
		SELECT re.id::text, re.date::text, re.score_a, re.score_b, re.target,
		       re.phase_weight,
		       coalesce(jsonb_agg(jsonb_build_object('p', rd.player_id::text, 't', rd.team)
		           ORDER BY rd.team, rd.player_id::text) FILTER (WHERE rd.player_id IS NOT NULL), '[]'::jsonb)
		FROM `+s.schema+`.rating_events re
		LEFT JOIN `+s.schema+`.rating_deltas rd ON rd.event_id = re.id
		GROUP BY re.id
		ORDER BY re.date ASC, re.created_at ASC, re.source_id ASC, re.game_order ASC`)
	if err != nil {
		return 0, err
	}

	events := []ev{}
	for rows.Next() {
		var e ev
		var playersJSON []byte
		if err := rows.Scan(&e.id, &e.date, &e.scoreA, &e.scoreB, &e.target,
			&e.phaseWeight, &playersJSON); err != nil {
			rows.Close()
			return 0, err
		}
		type pj struct {
			P string `json:"p"`
			T string `json:"t"`
		}
		var ps []pj
		if err := jsonUnmarshal(playersJSON, &ps); err != nil {
			rows.Close()
			return 0, err
		}
		for _, p := range ps {
			e.players = append(e.players, evPlayer{playerID: p.P, team: p.T})
		}
		events = append(events, e)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}

	// Reset semua state (setelah pemetaan event→pemain tersimpan di memori)
	if _, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.rating_players`); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.rating_deltas`); err != nil {
		return 0, err
	}

	// runtime state — forming ulang: baseline = tier assigned (players.tier).
	// Pemain tanpa tier → initial_rating (fallback).
	runtime := map[string]*playerRuntime{}
	getRT := func(id string) *playerRuntime {
		rt, ok := runtime[id]
		if !ok {
			rt = &playerRuntime{
				id:    id,
				state: domain.RatingState{Rating: cfg.Params.InitialRating, RD: cfg.Params.InitialRD},
				peak:  cfg.Params.InitialRating,
			}
			if tier := priorTier[id]; tier != "" {
				if mid, ok := cfg.MidRatingForTier(tier); ok {
					rt.state.Rating = mid
					rt.peak = mid
					rt.tier = tier
				}
			}
			runtime[id] = rt
		}
		return rt
	}

	// Proses ulang berurutan
	for _, e := range events {
		playersA := []string{}
		playersB := []string{}
		for _, p := range e.players {
			if p.team == "A" {
				playersA = append(playersA, p.playerID)
			} else {
				playersB = append(playersB, p.playerID)
			}
		}
		if len(playersA) == 0 || len(playersB) == 0 {
			continue // event tanpa salah satu sisi (data lama) — dilewati
		}

		phaseWeight := e.phaseWeight
		if phaseWeight <= 0 {
			phaseWeight = 1.0
		}
		movm := domain.MarginOfVictory(e.scoreA, e.scoreB, e.target, cfg.Params)
		outcomeA := 0.0
		if e.scoreA > e.scoreB {
			outcomeA = 1.0
		} else if e.scoreA == e.scoreB {
			outcomeA = 0.5
		}
		outcomeB := 1.0 - outcomeA

		oppsFor := func(myTeam string) []domain.RatingOpponent {
			opp := playersB
			if myTeam == "B" {
				opp = playersA
			}
			out := []domain.RatingOpponent{}
			for _, id := range opp {
				rt := getRT(id)
				out = append(out, domain.RatingOpponent{Rating: rt.state.Rating, RD: rt.state.RD})
			}
			return out
		}

		type u struct {
			rt   *playerRuntime
			team string
			out  float64
			opps []domain.RatingOpponent
		}
		updates := []u{}
		for _, id := range playersA {
			rt := getRT(id)
			updates = append(updates, u{rt: rt, team: "A", out: outcomeA, opps: oppsFor("A")})
		}
		for _, id := range playersB {
			rt := getRT(id)
			updates = append(updates, u{rt: rt, team: "B", out: outcomeB, opps: oppsFor("B")})
		}

		for _, x := range updates {
			st := x.rt.state
			if x.rt.lastPlayedAt != "" {
				d1, err1 := time.Parse("2006-01-02", x.rt.lastPlayedAt)
				d2, err2 := time.Parse("2006-01-02", e.date)
				if err1 == nil && err2 == nil && d2.After(d1) {
					st.RD = domain.GrowRD(st.RD, int(d2.Sub(d1).Hours()/24), cfg.Params)
				}
			}
			exp := 0.0
			if len(x.opps) > 0 {
				for _, o := range x.opps {
					exp += domain.ExpectedScore(st.Rating, o)
				}
				exp /= float64(len(x.opps))
			}
			newSt, delta := domain.GlickoUpdate(st, x.opps, x.out, movm, phaseWeight, cfg.Params)

			x.rt.state = newSt
			x.rt.games++
			if x.out == 1.0 {
				x.rt.wins++
			} else if x.out == 0.0 {
				x.rt.losses++
			}
			x.rt.lastPlayedAt = e.date
			if newSt.Rating > x.rt.peak {
				x.rt.peak = newSt.Rating
			}

			outcome := "W"
			if x.out == 0.0 {
				outcome = "L"
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO `+s.schema+`.rating_deltas
					(event_id, player_id, team, outcome, expected, movm, delta, new_rating)
				VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, $7, $8)`,
				e.id, x.rt.id, x.team, outcome, domain.Round4(exp), domain.Round4(movm), delta, newSt.Rating); err != nil {
				return 0, err
			}
		}
	}

	// Flush rating_players
	for id, rt := range runtime {
		var lastPlayed any
		if rt.lastPlayedAt != "" {
			lastPlayed = rt.lastPlayedAt
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO `+s.schema+`.rating_players
				(player_id, rating, rd, peak_rating, games_played, wins, losses, last_played_at, updated_at)
			VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8::date, now())
			ON CONFLICT (player_id) DO UPDATE SET
				rating = EXCLUDED.rating, rd = EXCLUDED.rd, peak_rating = EXCLUDED.peak_rating,
				games_played = EXCLUDED.games_played, wins = EXCLUDED.wins, losses = EXCLUDED.losses,
				last_played_at = EXCLUDED.last_played_at, updated_at = now()`,
			id, rt.state.Rating, rt.state.RD, rt.peak, rt.games, rt.wins, rt.losses, lastPlayed); err != nil {
			return 0, err
		}
	}

	// Reset-to-default: pemain yang sebelumnya ter-rating tapi kini 0 event
	// (semua game-nya di source yang di-revert) → mid tier (atau initial), 0 game.
	for id := range prior {
		if _, ok := runtime[id]; ok {
			continue
		}
		base := cfg.Params.InitialRating
		if tier := priorTier[id]; tier != "" {
			if mid, ok := cfg.MidRatingForTier(tier); ok {
				base = mid
			}
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO `+s.schema+`.rating_players
				(player_id, rating, rd, peak_rating, games_played, wins, losses, last_played_at, updated_at)
			VALUES ($1::uuid, $2, $3, $4, 0, 0, 0, NULL, now())
			ON CONFLICT (player_id) DO UPDATE SET
				rating = EXCLUDED.rating, rd = EXCLUDED.rd, peak_rating = EXCLUDED.peak_rating,
				games_played = 0, wins = 0, losses = 0, last_played_at = NULL, updated_at = now()`,
			id, base, cfg.Params.InitialRD, base); err != nil {
			return 0, err
		}
	}

	return len(runtime), nil
}

// jsonUnmarshal — wrapper encoding/json.Unmarshal (untuk pemain dari agg).
func jsonUnmarshal(b []byte, v any) error {
	return json.Unmarshal(b, v)
}
