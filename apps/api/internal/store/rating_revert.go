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
// Fix audit 2026-08-19: source_kind diambil dari format tournament asli
// (classic | team) — sebelumnya hardcode 'tournament_classic'.
func (s *SessionStore) SetSourceFinalized(ctx context.Context, sourceID string, finalized bool) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// Kind dari format tournament sebenarnya (default classic).
	kind := "tournament_classic"
	var format string
	err = tx.QueryRow(ctx, `
		SELECT format FROM `+s.schema+`.tournaments
		WHERE share_code = $1 OR id::text = $1
		ORDER BY (share_code = $1) DESC LIMIT 1`, sourceID).Scan(&format)
	if err == nil && format == "team" {
		kind = "tournament_team"
	} else if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return err
	}

	if _, err := tx.Exec(ctx, `
		INSERT INTO `+s.schema+`.rating_sources
			(source_id, source_kind, fingerprint, finalized, last_ingested_seq, ingested_at)
		VALUES ($1, $2, '', $3, 0, now())
		ON CONFLICT (source_id) DO UPDATE SET
			finalized = EXCLUDED.finalized, source_kind = EXCLUDED.source_kind`,
		sourceID, kind, finalized); err != nil {
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

// priorPlayer — benih musim berjalan untuk seorang pemain, dibaca dari kolom
// seed_* rating_players (disegel CloseAndStartSeason). Stabil lintas rebuild.
type priorPlayer struct {
	rating float64
	rd     float64 // 0 = belum disegel, pakai initial RD
}

// seedRow — nilai kolom seed_* apa adanya, untuk ditulis ulang setelah
// DELETE FROM rating_players.
type seedRow struct {
	rating *float64
	rd     *float64
	setAt  *time.Time
}

// rebuildAll — recompute SEMUA rating_players dari events tersisa, urut
// (date, created_at, source_id, game_order). Memakai stored phase_weight &
// target & scores dari rating_events; pemain dari rating_deltas (team).
func (s *SessionStore) rebuildAll(ctx context.Context, tx pgx.Tx, cfg domain.RatingConfig) (int, error) {
	// Tangkap pemain yang pernah ter-rating (untuk reset-to-default) + tier
	// assigned (players.tier — TIER_8_UNIFICATION) + BENIH musim berjalan.
	//
	// Benih dibaca dari kolom seed_* (disegel CloseAndStartSeason), BUKAN dari
	// rating saat ini. Kalau benih diambil dari rating_players.rating, rebuild
	// akan memakai hasil rebuild sebelumnya sebagai input → tidak idempotent
	// (terukur: rating naik tiap rebuild: 1495 → 1525 → 1554).
	priorRows, err := tx.Query(ctx, `
		SELECT rp.player_id::text, coalesce(p.tier, ''),
		       rp.seed_rating, rp.seed_rd, rp.seed_set_at
		FROM `+s.schema+`.rating_players rp
		LEFT JOIN `+s.schema+`.players p ON p.id = rp.player_id`)
	if err != nil {
		return 0, err
	}
	prior := map[string]bool{}
	priorTier := map[string]string{}
	priorState := map[string]priorPlayer{}
	// seedRows menyimpan benih apa adanya supaya bisa ditulis ulang setelah
	// DELETE FROM rating_players (yang menghapus kolom seed_* juga).
	seedRows := map[string]seedRow{}
	for priorRows.Next() {
		var id, tier string
		var seedRating, seedRD *float64
		var seedSetAt *time.Time
		if err := priorRows.Scan(&id, &tier, &seedRating, &seedRD, &seedSetAt); err != nil {
			priorRows.Close()
			return 0, err
		}
		prior[id] = true
		priorTier[id] = tier
		seedRows[id] = seedRow{rating: seedRating, rd: seedRD, setAt: seedSetAt}
		if seedRating != nil {
			pri := priorPlayer{rating: *seedRating}
			if seedRD != nil {
				pri.rd = *seedRD
			}
			priorState[id] = pri
		}
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
	// Hanya events ≥ season_start: Glicko bersifat musim-scoped (mulai dari
	// mid kelas tiap musim). Events lama tetap tersimpan di tabel untuk
	// ranking poin ber-window, tetapi tidak dihitung ke rating Glicko musim ini.
	rows, err := tx.Query(ctx, `
		SELECT re.id::text, re.date::text, re.score_a, re.score_b, re.target,
		       re.phase_weight,
		       coalesce(jsonb_agg(jsonb_build_object('p', rd.player_id::text, 't', rd.team)
		           ORDER BY rd.team, rd.player_id::text) FILTER (WHERE rd.player_id IS NOT NULL), '[]'::jsonb)
		FROM `+s.schema+`.rating_events re
		LEFT JOIN `+s.schema+`.rating_deltas rd ON rd.event_id = re.id
		WHERE re.date >= $1::date
		GROUP BY re.id
		ORDER BY re.date ASC, re.created_at ASC, re.source_id ASC, re.game_order ASC`,
		cfg.SeasonStart)
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
		if err := json.Unmarshal(playersJSON, &ps); err != nil {
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

	// Pengaman: rebuild menghapus rating_players + rating_deltas lalu menyusun
	// ulang dari pemetaan event→pemain di memori. Pemetaan itu HANYA bisa dibaca
	// dari rating_deltas — tabel yang akan dihapus. Jadi bila ada event dalam
	// musim tapi tidak ada satu pun pemetaan yang terbaca, rating_deltas hilang
	// atau tidak lengkap: melanjutkan berarti menulis ulang seluruh rating
	// sebagai kosong TANPA jalur pemulihan (rating_deltas adalah satu-satunya
	// sumber pemetaan). Menolak lebih baik daripada memusnahkan data.
	if len(events) > 0 {
		mapped := 0
		for i := range events {
			mapped += len(events[i].players)
		}
		if mapped == 0 {
			return 0, fmt.Errorf(
				"rebuild dibatalkan: %d event dalam musim tapi tidak ada pemetaan event→pemain; "+
					"rating_deltas kemungkinan kosong atau tidak lengkap — "+
					"rebuild akan menghapus seluruh rating tanpa bisa dipulihkan",
				len(events))
		}
	}

	// Reset semua state (setelah pemetaan event→pemain tersimpan di memori).
	// seedRows sudah dibaca di atas dan akan ditulis ulang di flush — DELETE
	// di sini memang menghapus kolom seed_*, itu disengaja supaya tidak ada
	// baris basi yang tertinggal.
	if _, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.rating_players`); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.rating_deltas`); err != nil {
		return 0, err
	}

	// runtime state — benih bergantung pada riwayat pemain:
	//   pemain BARU (belum pernah ter-rating)  → mid kelas (players.tier)
	//   pemain LAMA (punya riwayat ≥1 game)    → rating terakhir, RD ditumbuhkan
	// Tier tetap satu-satunya input generator; di sini tier hanya dipakai
	// sebagai titik awal pemain yang memang belum punya rating.
	runtime := map[string]*playerRuntime{}
	getRT := func(id string) *playerRuntime {
		rt, ok := runtime[id]
		if !ok {
			rt = &playerRuntime{
				id:    id,
				state: domain.RatingState{Rating: cfg.Params.InitialRating, RD: cfg.Params.InitialRD},
				peak:  cfg.Params.InitialRating,
			}
			if pri, hasSeed := priorState[id]; hasSeed {
				// Benih pemain lama: rating terakhir musim lalu, RD sudah
				// ditumbuhkan sesuai jeda saat musim ditutup. Disimpan di
				// kolom seed_* supaya rebuild tetap idempotent.
				rt.state.Rating = pri.rating
				if pri.rd > 0 {
					rt.state.RD = pri.rd
				}
				rt.peak = pri.rating
				if tier := priorTier[id]; tier != "" {
					rt.tier = tier
				}
			} else if tier := priorTier[id]; tier != "" {
				// Pemain baru dengan tier assigned → mid kelas.
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
			rt       *playerRuntime
			team     string
			out      float64
			opps     []domain.RatingOpponent
			teamSize int
		}
		updates := []u{}
		teamASize := len(playersA)
		teamBSize := len(playersB)
		for _, id := range playersA {
			rt := getRT(id)
			updates = append(updates, u{rt: rt, team: "A", out: outcomeA, opps: oppsFor("A"), teamSize: teamASize})
		}
		for _, id := range playersB {
			rt := getRT(id)
			updates = append(updates, u{rt: rt, team: "B", out: outcomeB, opps: oppsFor("B"), teamSize: teamBSize})
		}

		for _, x := range updates {
			if err := s.applyPlayerUpdate(ctx, tx, x.rt, x.team, x.out, x.opps, x.teamSize, movm, phaseWeight, e.date, e.id, cfg); err != nil {
				return 0, err
			}
		}
	}

	// Flush rating_players — dengan decay applied
	for id, rt := range runtime {
		// Apply decay: rating turun berdasarkan idle sejak game terakhir.
		// NOTE: peak_rating TIDAK ikut turun — peak adalah rekor tertinggi
		// yang pernah dicapai, bukan state saat ini.
		if cfg.DecayEnabled && rt.lastPlayedAt != "" {
			lastPlayed, err := time.Parse("2006-01-02", rt.lastPlayedAt)
			if err == nil {
				idleDays := int(time.Since(lastPlayed).Hours() / 24)
				if idleDays > cfg.DecayThresholdDays {
					rt.state.Rating = domain.DecayFactor(
						rt.state.Rating, idleDays, cfg.Params,
						cfg.DecayEnabled, cfg.DecayThresholdDays,
						cfg.DecayPerWeek, cfg.DecayFloor,
					)
				}
			}
		}

		var lastPlayed any
		if rt.lastPlayedAt != "" {
			lastPlayed = rt.lastPlayedAt
		}
		sr := seedRows[id]
		if _, err := tx.Exec(ctx, `
			INSERT INTO `+s.schema+`.rating_players
				(player_id, rating, rd, peak_rating, games_played, wins, losses, last_played_at,
				 seed_rating, seed_rd, seed_set_at, updated_at)
			VALUES ($1::uuid, $2, $3, $4, $5, $6, $7, $8::date, $9, $10, $11, now())
			ON CONFLICT (player_id) DO UPDATE SET
				rating = EXCLUDED.rating, rd = EXCLUDED.rd, peak_rating = EXCLUDED.peak_rating,
				games_played = EXCLUDED.games_played, wins = EXCLUDED.wins, losses = EXCLUDED.losses,
				last_played_at = EXCLUDED.last_played_at,
				seed_rating = EXCLUDED.seed_rating, seed_rd = EXCLUDED.seed_rd,
				seed_set_at = EXCLUDED.seed_set_at, updated_at = now()`,
			id, rt.state.Rating, rt.state.RD, rt.peak, rt.games, rt.wins, rt.losses, lastPlayed,
			sr.rating, sr.rd, sr.setAt); err != nil {
			return 0, err
		}
	}

	// Reset-to-default: pemain yang sebelumnya ter-rating tapi kini 0 event
	// (semua game-nya di luar musim berjalan / source yang di-revert).
	//
	// Pemain dengan BENIH memakai benihnya (rating terakhir musim lalu + RD
	// yang sudah tumbuh) — bukan mid kelas. Ini yang membedakan pemain lama
	// dari pemain baru; mengabaikan benih di sini membuat tiap ganti musim
	// pemain lama terlempar kembali ke mid kelas.
	for id := range prior {
		if _, ok := runtime[id]; ok {
			continue
		}
		base := cfg.Params.InitialRating
		baseRD := cfg.Params.InitialRD
		if pri, hasSeed := priorState[id]; hasSeed {
			base = pri.rating
			if pri.rd > 0 {
				baseRD = pri.rd
			}
		} else if tier := priorTier[id]; tier != "" {
			if mid, ok := cfg.MidRatingForTier(tier); ok {
				base = mid
			}
		}
		sr := seedRows[id]
		if _, err := tx.Exec(ctx, `
			INSERT INTO `+s.schema+`.rating_players
				(player_id, rating, rd, peak_rating, games_played, wins, losses, last_played_at,
				 seed_rating, seed_rd, seed_set_at, updated_at)
			VALUES ($1::uuid, $2, $3, $4, 0, 0, 0, NULL, $5, $6, $7, now())
			ON CONFLICT (player_id) DO UPDATE SET
				rating = EXCLUDED.rating, rd = EXCLUDED.rd, peak_rating = EXCLUDED.peak_rating,
				games_played = 0, wins = 0, losses = 0, last_played_at = NULL,
				seed_rating = EXCLUDED.seed_rating, seed_rd = EXCLUDED.seed_rd,
				seed_set_at = EXCLUDED.seed_set_at, updated_at = now()`,
			id, base, baseRD, base, sr.rating, sr.rd, sr.setAt); err != nil {
			return 0, err
		}
	}

	return len(runtime), nil
}
