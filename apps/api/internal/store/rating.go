package store

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
)

// ── Rating ingest engine (RATING_ENGINE_DESIGN.md §4.3) ───────────────────
// Satu transaksi REPEATABLE READ + advisory lock global + lock player sorted
// + invariant seq. Idempotent via match_key; edit terdeteksi via fingerprint.

var (
	// ErrSourceChanged — fingerprint sumber berbeda dari ingest terakhir.
	ErrSourceChanged = errors.New("rating: source changed since last ingest — revert first")
	// ErrOutOfOrder — batch tidak boleh diingest sebelum source yang lebih baru.
	ErrOutOfOrder = errors.New("rating: out-of-order ingest — process sources chronologically")
	// ErrSourceNotFound — source tidak ditemukan.
	ErrSourceNotFound = errors.New("rating: source not found")
	// ErrSourceNotFinal — gate lock/finalized belum terpenuhi.
	ErrSourceNotFinal = errors.New("rating: source not final (session unlocked / tournament not finalized)")
)

// AutoIngestLockedSessions — ingest otomatis sesi yang sudah final (status
// != draft) tapi belum pernah diingest (tidak ada rating_sources dengan
// fingerprint terisi). Urut kronologis. Idempotent; sesi yang diedit setelah
// ingest (fingerprint berubah) TIDAK disentuh — butuh revert manual.
// Dipanggil ticker setelah AutoLockExpiredSessions (plan frontend §4.3).
func (s *SessionStore) AutoIngestLockedSessions(ctx context.Context) (int, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT share_code
		FROM `+s.schema+`.sessions s
		WHERE s.status != 'draft'
		  AND NOT EXISTS (
			SELECT 1 FROM `+s.schema+`.rating_sources rs
			WHERE rs.source_id = s.share_code AND rs.fingerprint != ''
		  )
		ORDER BY s.session_date ASC, s.created_at ASC`)
	if err != nil {
		return 0, err
	}
	defer rows.Close()

	ingested := 0
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return ingested, err
		}
		if _, err := s.IngestSession(ctx, id); err != nil {
			// Jangan block sesi lain — log via return (caller log).
			continue
		}
		ingested++
	}
	return ingested, rows.Err()
}

// IngestResult — ringkasan ingest.
type IngestResult struct {
	Processed int           `json:"processed"`
	Skipped   []SkippedGame `json:"skipped"`
	Players   int           `json:"players"`
	Reconcile bool          `json:"reconcile"`
}

// SkippedGame — game yang dilewati + alasan.
type SkippedGame struct {
	GameRef string `json:"game_ref"`
	Reason  string `json:"reason"`
}

// sourceMeta — metadata sumber yang diekstrak.
type sourceMeta struct {
	Kind        string    // session | tournament_classic | tournament_team
	SourceID    string    // share_code (API id)
	Date        string    // yyyy-mm-dd
	CreatedAt   time.Time // basis ordering
	Fingerprint string
	Final       bool // status lock (session) / finalized (tournament)
	Title       string
}

// extractor — baca sumber → matches + meta (dalam tx yang sama).
type extractor func(ctx context.Context, tx pgx.Tx, lookup string) ([]domain.RawMatch, *sourceMeta, error)

// ingest — pipeline umum (design §4.3). Dipanggil oleh IngestSession /
// IngestTournament dengan extractor yang sesuai.
func (s *SessionStore) ingest(ctx context.Context, lookup string, ex extractor) (*IngestResult, error) {
	cfg, err := s.LoadRatingConfig(ctx, false)
	if err != nil {
		return nil, err
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// Advisory lock global ingest (design §4.3.2 / C4) — mem-blokir ingest & revert lain.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`,
		s.schema+":ratings_ingest"); err != nil {
		return nil, err
	}

	matches, meta, err := ex(ctx, tx, lookup)
	if err != nil {
		return nil, err
	}
	if meta == nil {
		return nil, fmt.Errorf("%w: %s", ErrSourceNotFound, lookup)
	}

	// Gate final (design §4.5): session harus locked, tournament harus finalized.
	if cfg.IngestLockedOnly && !meta.Final {
		return nil, fmt.Errorf("%w: %s", ErrSourceNotFinal, meta.SourceID)
	}

	// Fingerprint — edit detection (§4.4)
	var existingFP *string
	err = tx.QueryRow(ctx,
		`SELECT fingerprint FROM `+s.schema+`.rating_sources WHERE source_id = $1`,
		meta.SourceID).Scan(&existingFP)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	reconcile := false
	if err == nil { // source sudah pernah diingest
		// fingerprint '' = row cuma dibuat untuk finalized (belum pernah
		// diingest) → ingest pertama berjalan normal (bukan 409).
		if *existingFP != "" && *existingFP == meta.Fingerprint {
			return &IngestResult{Processed: 0}, nil // no-op
		}
		if *existingFP != "" {
			if !cfg.AutoReconcile {
				return nil, fmt.Errorf("%w: %s", ErrSourceChanged, meta.SourceID)
			}
			reconcile = true
			if err := s.deleteSourceEvents(ctx, tx, meta.SourceID); err != nil {
				return nil, err
			}
		}
	}

	// Filter void games (absent_policy=skip_game). Fingerprint TETAP dari
	// semua match (termasuk void) — §4.4a.
	playable := make([]domain.RawMatch, 0, len(matches))
	skipped := []SkippedGame{}
	for _, m := range matches {
		if m.Void() {
			skipped = append(skipped, SkippedGame{GameRef: m.StableGameID, Reason: "void (absent)"})
			continue
		}
		playable = append(playable, m)
	}
	domain.SortMatchesByOrder(playable)

	if len(playable) == 0 {
		return &IngestResult{Processed: 0, Skipped: skipped, Players: 0, Reconcile: reconcile}, nil
	}

	// Invariant seq (§4.3.7): min order batch harus > max order existing.
	var maxDate *string
	var maxCreated *time.Time
	var maxSource *string
	err = tx.QueryRow(ctx, `
		SELECT date::text, created_at, source_id FROM `+s.schema+`.rating_events
		ORDER BY date DESC, created_at DESC, source_id DESC, game_order DESC LIMIT 1`).
		Scan(&maxDate, &maxCreated, &maxSource)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	if err == nil {
		batchCreated := meta.CreatedAt
		if playable[0].Date < *maxDate ||
			(playable[0].Date == *maxDate && batchCreated.Before(*maxCreated)) ||
			(playable[0].Date == *maxDate && batchCreated.Equal(*maxCreated) && meta.SourceID <= *maxSource) {
			return nil, fmt.Errorf("%w: source %s (date %s)", ErrOutOfOrder, meta.SourceID, playable[0].Date)
		}
	}

	// Dedupe match_key dalam batch + skip yang sudah ada (idempotent)
	seen := map[string]bool{}
	fresh := make([]domain.RawMatch, 0, len(playable))
	for _, m := range playable {
		k := m.MatchKey()
		if seen[k] {
			skipped = append(skipped, SkippedGame{GameRef: m.StableGameID, Reason: "duplicate in batch"})
			continue
		}
		seen[k] = true
		var exists bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM `+s.schema+`.rating_events WHERE match_key = $1)`, k).Scan(&exists); err != nil {
			return nil, err
		}
		if exists {
			skipped = append(skipped, SkippedGame{GameRef: m.StableGameID, Reason: "already ingested"})
			continue
		}
		fresh = append(fresh, m)
	}
	if len(fresh) == 0 {
		return &IngestResult{Processed: 0, Skipped: skipped, Players: 0, Reconcile: reconcile}, nil
	}

	// Resolve nama → player_id (real player)
	playerIDs, err := s.resolveRatingPlayers(ctx, tx, fresh)
	if err != nil {
		return nil, err
	}

	// Lock player sorted (anti-deadlock, §4.3.8) — id player (VALUE map), bukan nama
	ids := make([]string, 0, len(playerIDs))
	for _, pid := range playerIDs {
		ids = append(ids, pid)
	}
	sort.Strings(ids)
	if len(ids) > 0 {
		if _, err := tx.Exec(ctx,
			`SELECT player_id FROM `+s.schema+`.rating_players WHERE player_id = ANY($1::uuid[]) FOR UPDATE`, ids); err != nil {
			return nil, err
		}
	}

	// Muat state runtime per pemain (dari DB atau default)
	runtime := map[string]*playerRuntime{}
	for _, id := range ids {
		// Default dulu — state {0,0} akan merusak math (bug ditemukan audit P1)
		rt := &playerRuntime{
			id:    id,
			state: domain.RatingState{Rating: cfg.Params.InitialRating, RD: cfg.Params.InitialRD},
			peak:  cfg.Params.InitialRating,
		}
		var lastPlayed *time.Time
		err := tx.QueryRow(ctx, `
			SELECT rating, rd, peak_rating, games_played, wins, losses, last_played_at
			FROM `+s.schema+`.rating_players WHERE player_id = $1::uuid`, id).
			Scan(&rt.state.Rating, &rt.state.RD, &rt.peak, &rt.games, &rt.wins, &rt.losses, &lastPlayed)
		if err == nil {
			rt.exists = true
			if lastPlayed != nil {
				rt.lastPlayedAt = lastPlayed.Format("2006-01-02")
			}
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		runtime[id] = rt
	}

	// Proses berurutan (§4.3.9)
	var lastInsertedSeq int64
	for _, m := range fresh {
		eventID, err := s.insertRatingEvent(ctx, tx, &m, meta, cfg)
		if err != nil {
			return nil, err
		}
		if err := tx.QueryRow(ctx, `SELECT lastval()`).Scan(&lastInsertedSeq); err != nil {
			return nil, err
		}

		phaseWeight := cfg.PhaseWeights[m.Phase]
		if phaseWeight <= 0 {
			phaseWeight = 1.0
		}
		movm := domain.MarginOfVictory(m.ScoreA, m.ScoreB, m.Target, cfg.Params)
		outcomeA := 0.0
		if m.ScoreA > m.ScoreB {
			outcomeA = 1.0
		} else if m.ScoreA == m.ScoreB {
			outcomeA = 0.5
		}
		outcomeB := 1.0 - outcomeA

		// opponent helper: real lawan + placeholder sintetik (rate_as_unknown)
		opponentsFor := func(myTeam string) []domain.RatingOpponent {
			oppTeam := "B"
			if myTeam == "B" {
				oppTeam = "A"
			}
			opps := []domain.RatingOpponent{}
			for _, op := range m.PlayersByTeam(oppTeam) {
				if ort := runtime[playerIDs[op.Name]]; ort != nil {
					opps = append(opps, domain.RatingOpponent{Rating: ort.state.Rating, RD: ort.state.RD})
				}
			}
			for _, _ = range m.PlaceholdersByTeam(oppTeam) {
				opps = append(opps, domain.RatingOpponent{Rating: cfg.Params.InitialRating, RD: cfg.Params.InitialRD})
			}
			return opps
		}

		type updateEntry struct {
			rt   *playerRuntime
			team string
			out  float64
			opps []domain.RatingOpponent
		}
		updates := []updateEntry{}
		for _, p := range m.PlayersByTeam("A") {
			if rt := runtime[playerIDs[p.Name]]; rt != nil {
				updates = append(updates, updateEntry{rt: rt, team: "A", out: outcomeA, opps: opponentsFor("A")})
			}
		}
		for _, p := range m.PlayersByTeam("B") {
			if rt := runtime[playerIDs[p.Name]]; rt != nil {
				updates = append(updates, updateEntry{rt: rt, team: "B", out: outcomeB, opps: opponentsFor("B")})
			}
		}

		for _, u := range updates {
			// GrowRD by idle days (basis tanggal sumber — deterministik)
			st := u.rt.state
			if u.rt.lastPlayedAt != "" {
				d1, err1 := time.Parse("2006-01-02", u.rt.lastPlayedAt)
				d2, err2 := time.Parse("2006-01-02", m.Date)
				if err1 == nil && err2 == nil && d2.After(d1) {
					st.RD = domain.GrowRD(st.RD, int(d2.Sub(d1).Hours()/24), cfg.Params)
				}
			}

			exp := 0.0
			if len(u.opps) > 0 {
				for _, o := range u.opps {
					exp += domain.ExpectedScore(st.Rating, o)
				}
				exp /= float64(len(u.opps))
			}

			newSt, delta := domain.GlickoUpdate(st, u.opps, u.out, movm, phaseWeight, cfg.Params)

			u.rt.state = newSt
			u.rt.games++
			if u.out == 1.0 {
				u.rt.wins++
			} else if u.out == 0.0 {
				u.rt.losses++
			}
			u.rt.lastPlayedAt = m.Date
			if newSt.Rating > u.rt.peak {
				u.rt.peak = newSt.Rating
			}

			outcome := "W"
			if u.out == 0.0 {
				outcome = "L"
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO `+s.schema+`.rating_deltas
					(event_id, player_id, team, outcome, expected, movm, delta, new_rating)
				VALUES ($1::uuid, $2::uuid, $3, $4, $5, $6, $7, $8)`,
				eventID, u.rt.id, u.team, outcome, domain.Round4(exp), domain.Round4(movm), delta, newSt.Rating); err != nil {
				return nil, err
			}
		}
	}

	// Flush rating_players + rating_sources
	for _, id := range ids {
		rt := runtime[id]
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
			return nil, err
		}
	}

	if _, err := tx.Exec(ctx, `
		INSERT INTO `+s.schema+`.rating_sources
			(source_id, source_kind, fingerprint, finalized, last_ingested_seq, ingested_at)
		VALUES ($1, $2, $3, $4, $5, now())
		ON CONFLICT (source_id) DO UPDATE SET
			fingerprint = EXCLUDED.fingerprint,
			last_ingested_seq = EXCLUDED.last_ingested_seq,
			ingested_at = now()`,
		meta.SourceID, meta.Kind, meta.Fingerprint, meta.Final, lastInsertedSeq); err != nil {
		return nil, err
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	return &IngestResult{Processed: len(fresh), Skipped: skipped, Players: len(ids), Reconcile: reconcile}, nil
}

// deleteSourceEvents — hapus events + deltas by source_id (revert/reconcile).
func (s *SessionStore) deleteSourceEvents(ctx context.Context, tx pgx.Tx, sourceID string) error {
	// rating_deltas cascade dari rating_events — cukup hapus events.
	_, err := tx.Exec(ctx, `DELETE FROM `+s.schema+`.rating_events WHERE source_id = $1`, sourceID)
	return err
}

// resolveRatingPlayers — resolve nama → player_id (auto-register TOCTOU-safe);
// mengembalikan map nama → player_id untuk pemain REAL (bukan placeholder).
func (s *SessionStore) resolveRatingPlayers(ctx context.Context, tx pgx.Tx, matches []domain.RawMatch) (map[string]string, error) {
	out := map[string]string{}
	seen := map[string]bool{}
	for _, m := range matches {
		for _, p := range m.Players {
			if p.Placeholder || p.Name == "" {
				continue
			}
			if seen[p.Name] {
				continue
			}
			seen[p.Name] = true
			pid, ok, err := resolveTournamentPlayer(ctx, tx, p.Name)
			if err != nil {
				return nil, err
			}
			if ok {
				out[p.Name] = pid
			}
		}
	}
	return out, nil
}

// insertRatingEvent — tulis rating_events (idempotent via match_key).
func (s *SessionStore) insertRatingEvent(ctx context.Context, tx pgx.Tx, m *domain.RawMatch, meta *sourceMeta, cfg domain.RatingConfig) (string, error) {
	var id string
	err := tx.QueryRow(ctx, `
		INSERT INTO `+s.schema+`.rating_events
			(match_key, kind, source_id, source_fingerprint, stable_game_id, date, created_at,
			 game_order, title, score_a, score_b, target, phase, phase_weight, processed_at)
		VALUES ($1, $2, $3, $4, $5, $6::date, $7, $8, $9, $10, $11, $12, $13, $14, now())
		ON CONFLICT (match_key) DO NOTHING
		RETURNING id::text`,
		m.MatchKey(), m.Kind, meta.SourceID, meta.Fingerprint, m.StableGameID, m.Date,
		meta.CreatedAt, m.GameOrder, m.Title, m.ScoreA, m.ScoreB, m.Target, m.Phase,
		cfg.PhaseWeights[m.Phase]).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", fmt.Errorf("rating: match_key %s already ingested", m.MatchKey())
	}
	if err != nil {
		return "", err
	}
	return id, nil
}

// playerRuntime — state in-memory selama ingest.
type playerRuntime struct {
	id           string
	state        domain.RatingState
	peak         float64
	games        int
	wins         int
	losses       int
	lastPlayedAt string
	exists       bool
}
