package store

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TournamentStore — akses tournament. Write-path (publish) dan read-path
// (rebuild snapshot) dijalankan langsung di Go — port bm.publish_tournament /
// bm.get_tournament.
type TournamentStore struct {
	pool *pgxpool.Pool
	// schema — nama schema aktif (bm / bm_dev) untuk namespace advisory lock.
	schema string
}

// NewTournamentStore — buat TournamentStore dengan pool + schema.
func NewTournamentStore(pool *pgxpool.Pool, schema string) *TournamentStore {
	return &TournamentStore{pool: pool, schema: schema}
}

// Load — read-path (port bm.get_tournament): rebuild TournamentSnapshot dari
// tabel relasional.
func (s *TournamentStore) Load(ctx context.Context, id string) (*domain.TournamentSnapshot, error) {
	if id = strings.TrimSpace(id); id == "" {
		return nil, ErrNotFound
	}
	// Resolve lookup (share_code / uuid) — mirror resolve_tournament_lookup.
	var tournamentID string
	err := s.pool.QueryRow(ctx, `
		SELECT t.id::text FROM tournaments t
		WHERE t.share_code = $1 OR t.id::text = $1
		ORDER BY (t.share_code = $1) DESC
		LIMIT 1`, id).Scan(&tournamentID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	// Header
	var (
		name    string
		date    string
		version int
	)
	if err := s.pool.QueryRow(ctx, `
		SELECT name, event_date::text, version FROM tournaments WHERE id = $1::uuid`,
		tournamentID).Scan(&name, &date, &version); err != nil {
		return nil, err
	}

	snap := &domain.TournamentSnapshot{
		Version: &version,
		Format:  "classic",
		Name:    name,
		Date:    date,
		Pairs:   []domain.TournamentPair{},
		Groups:  map[string][]string{},
		Matches: []domain.TournamentMatch{},
	}

	// Pairs — id "pN" (seed), name. (players per pair tidak di-emit.)
	rows, err := s.pool.Query(ctx, `
		SELECT tp.seed, tp.pair_name FROM tournament_pairs tp
		WHERE tp.tournament_id = $1::uuid
		ORDER BY tp.seed`, tournamentID)
	if err != nil {
		return nil, err
	}
	seedToID := map[int]string{} // seed → "pN"
	for rows.Next() {
		var (
			seed int
			name string
		)
		if err := rows.Scan(&seed, &name); err != nil {
			rows.Close()
			return nil, err
		}
		pairID := fmt.Sprintf("p%d", seed)
		seedToID[seed] = pairID
		snap.Pairs = append(snap.Pairs, domain.TournamentPair{ID: pairID, Name: name})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Groups — group_id → ["pN" ordered by position]
	rows, err = s.pool.Query(ctx, `
		SELECT tg.group_id, tp.seed
		FROM tournament_groups tg
		JOIN tournament_pairs tp ON tp.id = tg.pair_id
		WHERE tg.tournament_id = $1::uuid
		ORDER BY tg.group_id, tg.position`, tournamentID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var (
			groupID string
			seed    int
		)
		if err := rows.Scan(&groupID, &seed); err != nil {
			rows.Close()
			return nil, err
		}
		snap.Groups[groupID] = append(snap.Groups[groupID], fmt.Sprintf("p%d", seed))
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Matches — mirror get_tournament: group match punya groupId+picName,
	// knockout tidak.
	rows, err = s.pool.Query(ctx, `
		SELECT tm.match_key, tm.phase, tm.group_id, tm.score_a, tm.score_b,
		       tp_a.seed, tp_b.seed, pl.canonical_name
		FROM tournament_matches tm
		LEFT JOIN tournament_pairs tp_a ON tp_a.id = tm.pair_a_id
		LEFT JOIN tournament_pairs tp_b ON tp_b.id = tm.pair_b_id
		LEFT JOIN players pl ON pl.id = tm.pic_player_id
		WHERE tm.tournament_id = $1::uuid
		ORDER BY tm.match_order`, tournamentID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var (
			key, phase     string
			groupID        *string
			scoreA, scoreB *int
			seedA, seedB   *int
			picName        *string
		)
		if err := rows.Scan(&key, &phase, &groupID, &scoreA, &scoreB, &seedA, &seedB, &picName); err != nil {
			rows.Close()
			return nil, err
		}
		m := domain.TournamentMatch{
			ID:     key,
			Phase:  phase,
			ScoreA: scoreA,
			ScoreB: scoreB,
		}
		if groupID != nil {
			m.GroupID = *groupID
		}
		if seedA != nil {
			id := fmt.Sprintf("p%d", *seedA)
			m.PairAID = &id
		}
		if seedB != nil {
			id := fmt.Sprintf("p%d", *seedB)
			m.PairBID = &id
		}
		if phase == "group" && picName != nil {
			m.PICName = picName
		}
		snap.Matches = append(snap.Matches, m)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return snap, nil
}

// TournamentMeta — baris list tournament (GET /tournaments).
type TournamentMeta struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Date   string `json:"date"`
	Format string `json:"format"`
}

// List — daftar metadata semua tournament, terbaru dulu.
func (s *TournamentStore) List(ctx context.Context) ([]TournamentMeta, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT share_code, name, event_date::text, format
		FROM tournaments
		ORDER BY event_date DESC, updated_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]TournamentMeta, 0)
	for rows.Next() {
		var m TournamentMeta
		if err := rows.Scan(&m.ID, &m.Name, &m.Date, &m.Format); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// Save — publish write-path (port bm.publish_tournament): satu transaksi
// berisi validasi, advisory lock, version check, upsert header, lalu
// delete-and-reinsert child tables (pairs, pair_players, groups, matches).
func (s *TournamentStore) Save(ctx context.Context, id string, snap *domain.TournamentSnapshot) (*domain.TournamentSnapshot, error) {
	if id = strings.TrimSpace(id); id == "" {
		return nil, fmt.Errorf("%w: tournament id must not be blank", ErrValidation)
	}
	if err := domain.ValidateTournamentSnapshot(snap); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrValidation, err)
	}

	name := snap.Name
	date := snap.Date
	if date == "" {
		date = "2006-01-02" // tidak akan terjadi — validasi mewajibkan date
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// Advisory lock — namespace schema dari config (bm / bm_dev).
	var locked bool
	if err := tx.QueryRow(ctx,
		`SELECT pg_try_advisory_xact_lock(hashtextextended($1 || ':' || $2, 0))`,
		s.schema+".publish_tournament", id).Scan(&locked); err != nil {
		return nil, err
	}
	if !locked {
		return nil, ErrContention
	}

	var (
		rowID      string
		currentVer int
		found      bool
	)
	err = tx.QueryRow(ctx, `
		SELECT t.id::text, t.version FROM tournaments t
		WHERE t.share_code = $1 OR t.id::text = $1
		ORDER BY (t.share_code = $1) DESC
		LIMIT 1
		FOR UPDATE NOWAIT`, id).Scan(&rowID, &currentVer)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		found = false
	case err != nil:
		if isLockNotAvailable(err) {
			return nil, ErrContention
		}
		return nil, err
	default:
		found = true
	}

	expected := snap.Version
	var nextVersion int
	switch {
	case found:
		if expected != nil && *expected != currentVer {
			return nil, fmt.Errorf("%w: expected %d, actual %d", ErrVersionMismatch, *expected, currentVer)
		}
		nextVersion = currentVer + 1
	default:
		if expected != nil {
			return nil, fmt.Errorf("%w: expected %d, actual null", ErrVersionMismatch, *expected)
		}
		nextVersion = 1
	}

	// Upsert header
	if found {
		if _, err := tx.Exec(ctx, `
			UPDATE tournaments SET name = $2, event_date = $3::date, version = $4, updated_at = now()
			WHERE id = $1::uuid`, rowID, name, date, nextVersion); err != nil {
			return nil, err
		}
	} else {
		if err := tx.QueryRow(ctx, `
			INSERT INTO tournaments (share_code, name, event_date, version)
			VALUES ($1, $2, $3::date, $4)
			RETURNING id::text`, id, name, date, nextVersion).Scan(&rowID); err != nil {
			return nil, err
		}
	}

	// Delete-and-reinsert child (pola sama dengan publish_session)
	if _, err := tx.Exec(ctx, `DELETE FROM tournament_matches WHERE tournament_id = $1::uuid`, rowID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM tournament_groups WHERE tournament_id = $1::uuid`, rowID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `
		DELETE FROM tournament_pair_players WHERE pair_id IN (SELECT id FROM tournament_pairs WHERE tournament_id = $1::uuid)`,
		rowID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM tournament_pairs WHERE tournament_id = $1::uuid`, rowID); err != nil {
		return nil, err
	}

	// seedByID — "pN" → seed (untuk resolve pair di groups/matches)
	seedByID := map[string]int{}
	seedToInternal := map[int]string{} // seed → internal_id (uuid)
	for i, p := range snap.Pairs {
		seed := i + 1
		if strings.HasPrefix(p.ID, "p") {
			if n, err := parseSeed(p.ID); err == nil {
				seed = n
			}
		}
		seedByID[p.ID] = seed
		var pairRowID string
		if err := tx.QueryRow(ctx, `
			INSERT INTO tournament_pairs (tournament_id, pair_name, seed)
			VALUES ($1, $2, $3)
			RETURNING id::text`, rowID, p.Name, seed).Scan(&pairRowID); err != nil {
			return nil, err
		}
		seedToInternal[seed] = pairRowID
		// pair_players: parse "X & Y" → resolve per nama (port resolve_tournament_player)
		for _, part := range splitPairNames(p.Name) {
			pid, ok, err := resolveTournamentPlayer(ctx, tx, part)
			if err != nil {
				return nil, err
			}
			if !ok {
				continue
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO tournament_pair_players (pair_id, player_id) VALUES ($1::uuid, $2::uuid)`,
				pairRowID, pid); err != nil {
				return nil, err
			}
		}
	}

	// Groups — group_id → ["pN" ...] (position = ordinality 1-based)
	for groupID, pairIDs := range snap.Groups {
		for pos, pairID := range pairIDs {
			seed, ok := seedByID[pairID]
			if !ok {
				continue
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO tournament_groups (tournament_id, group_id, pair_id, position)
				VALUES ($1::uuid, $2, $3::uuid, $4)`,
				rowID, groupID, seedToInternal[seed], pos+1); err != nil {
				return nil, err
			}
		}
	}

	// Matches — pair_a/b resolve ke internal uuid; pic via resolve_tournament_player
	for i, m := range snap.Matches {
		matchKey := m.ID
		if matchKey == "" {
			matchKey = fmt.Sprintf("m-%d", i)
		}
		var pairAInternal, pairBInternal *string
		if m.PairAID != nil {
			if seed, ok := seedByID[*m.PairAID]; ok {
				if id := seedToInternal[seed]; id != "" {
					pairAInternal = &id
				}
			}
		}
		if m.PairBID != nil {
			if seed, ok := seedByID[*m.PairBID]; ok {
				if id := seedToInternal[seed]; id != "" {
					pairBInternal = &id
				}
			}
		}
		var picID *string
		if m.PICName != nil {
			if pid, ok, err := resolveTournamentPlayer(ctx, tx, *m.PICName); err != nil {
				return nil, err
			} else if ok {
				picID = &pid
			}
		}
		var groupID *string
		if m.GroupID != "" {
			g := m.GroupID
			groupID = &g
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO tournament_matches
				(tournament_id, phase, group_id, pair_a_id, pair_b_id, score_a, score_b, pic_player_id, match_order, match_key)
			VALUES ($1::uuid, $2, $3, $4::uuid, $5::uuid, $6, $7, $8::uuid, $9, $10)`,
			rowID, m.Phase, groupID, pairAInternal, pairBInternal, m.ScoreA, m.ScoreB, picID, i, matchKey); err != nil {
			return nil, err
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return s.Load(ctx, id)
}

// ── helpers ───────────────────────────────────────────────────────────────

// parseSeed — "pN" → N.
func parseSeed(id string) (int, error) {
	var n int
	_, err := fmt.Sscanf(id, "p%d", &n)
	return n, err
}

// splitPairNames — pecah "X & Y" menjadi nama individu (port regexp_split
// dengan separator &, vs, ,, /, -).
func splitPairNames(name string) []string {
	var out []string
	for _, part := range strings.FieldsFunc(name, func(r rune) bool {
		switch r {
		case '&', 'v', 's', ',', '/', '-':
			// 'vs' ditangani secara kata di bawah; di sini & , / - saja
			return r == '&' || r == ',' || r == '/' || r == '-'
		}
		return false
	}) {
		part = strings.TrimSpace(part)
		// handle "vs" sebagai separator kata
		for _, sub := range strings.Split(part, "vs") {
			if t := strings.TrimSpace(sub); t != "" {
				out = append(out, t)
			}
		}
	}
	if len(out) == 0 {
		if t := strings.TrimSpace(name); t != "" {
			out = append(out, t)
		}
	}
	return out
}

// resolveTournamentPlayer — port bm.resolve_tournament_player: placeholder
// → (false); yang belum terdaftar di-auto-register (TOCTOU-safe).
func resolveTournamentPlayer(ctx context.Context, tx pgx.Tx, name string) (string, bool, error) {
	v := strings.TrimSpace(name)
	if v == "" || strings.HasPrefix(strings.ToLower(v), "x") || v == "-" || v == "?" {
		return "", false, nil
	}
	norm := domain.NormalizePlayerName(v)
	if norm == "" {
		return "", false, nil
	}
	var pid string
	err := tx.QueryRow(ctx, `SELECT player_id::text FROM player_aliases WHERE alias_name = $1`, norm).Scan(&pid)
	if err == nil {
		return pid, true, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return "", false, err
	}
	pid, err = registerPlayerInTx(ctx, tx, v, v)
	if err != nil {
		return "", false, err
	}
	return pid, true, nil
}

// registerPlayerInTx — port bm.register_player: idempotent + TOCTOU-safe
// (re-query alias setelah INSERT ON CONFLICT DO NOTHING).
func registerPlayerInTx(ctx context.Context, tx pgx.Tx, name, canonical string) (string, error) {
	aliasNorm := domain.NormalizePlayerName(name)
	if aliasNorm == "" {
		return "", fmt.Errorf("%w: player name must not be blank", ErrValidation)
	}
	var pid string
	err := tx.QueryRow(ctx, `SELECT player_id::text FROM player_aliases WHERE alias_name = $1`, aliasNorm).Scan(&pid)
	if err == nil {
		return pid, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return "", err
	}

	// canonical resolve (mirror: alias canonical → player existing)
	canonNorm := domain.NormalizePlayerName(canonical)
	if canonNorm != "" && canonNorm != aliasNorm {
		err := tx.QueryRow(ctx, `SELECT player_id::text FROM player_aliases WHERE alias_name = $1`, canonNorm).Scan(&pid)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return "", err
		}
	}
	if pid == "" {
		// ensure_player: insert players, ON CONFLICT → return existing id
		if err := tx.QueryRow(ctx, `
			INSERT INTO players (canonical_name) VALUES ($1)
			ON CONFLICT (canonical_name) DO UPDATE
				SET canonical_name = EXCLUDED.canonical_name, updated_at = now()
			RETURNING id::text`, strings.TrimSpace(canonical)).Scan(&pid); err != nil {
			return "", err
		}
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO player_aliases (alias_name, player_id) VALUES ($1, $2::uuid)
		ON CONFLICT (alias_name) DO NOTHING`, aliasNorm, pid); err != nil {
		return "", err
	}
	// Re-query — TOCTOU-safe: kalau ada request lain menang race, pakai id mereka.
	err = tx.QueryRow(ctx, `SELECT player_id::text FROM player_aliases WHERE alias_name = $1`, aliasNorm).Scan(&pid)
	return pid, err
}
