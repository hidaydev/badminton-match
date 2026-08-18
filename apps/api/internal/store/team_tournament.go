package store

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
)

// TournamentFormat — format tournament ('classic' | 'team').
func (s *TournamentStore) TournamentFormat(ctx context.Context, id string) (string, error) {
	if id = strings.TrimSpace(id); id == "" {
		return "", ErrNotFound
	}
	var format string
	err := s.pool.QueryRow(ctx, `
		SELECT format FROM tournaments
		WHERE share_code = $1 OR id::text = $1
		ORDER BY (share_code = $1) DESC
		LIMIT 1`, id).Scan(&format)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	return format, nil
}

// TeamLoad — rebuild TeamTournamentSnapshot dari tabel relasional team.
func (s *TournamentStore) TeamLoad(ctx context.Context, id string) (*domain.TeamTournamentSnapshot, error) {
	if id = strings.TrimSpace(id); id == "" {
		return nil, ErrNotFound
	}
	var tournamentID, name, date string
	var version int
	err := s.pool.QueryRow(ctx, `
		SELECT t.id::text, t.name, t.event_date::text, t.version
		FROM tournaments t
		WHERE t.share_code = $1 OR t.id::text = $1
		ORDER BY (t.share_code = $1) DESC
		LIMIT 1`, id).Scan(&tournamentID, &name, &date, &version)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}

	snap := &domain.TeamTournamentSnapshot{
		Version: &version,
		Format:  "team",
		Name:    name,
		Date:    date,
		Teams:   []domain.TeamInfo{},
		Matches: []domain.TeamMatch{},
	}

	// teams + players (urut seed, cls sesuai urutan TeamClasses)
	rows, err := s.pool.Query(ctx, `
		SELECT tt.seed, tt.team_name, tt.id::text
		FROM tournament_teams tt
		WHERE tt.tournament_id = $1::uuid
		ORDER BY tt.seed`, tournamentID)
	if err != nil {
		return nil, err
	}
	type teamRow struct {
		info domain.TeamInfo
		seed int
	}
	teams := []teamRow{}
	for rows.Next() {
		var (
			seed int
			tr   teamRow
		)
		if err := rows.Scan(&seed, &tr.info.Name, &tr.info.ID); err != nil {
			rows.Close()
			return nil, err
		}
		tr.seed = seed
		tr.info.Players = []domain.TeamPlayer{}
		teams = append(teams, tr)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// players per team
	rows, err = s.pool.Query(ctx, `
		SELECT ttp.team_id::text, ttp.player_name, ttp.cls
		FROM tournament_team_players ttp
		JOIN tournament_teams tt ON tt.id = ttp.team_id
		WHERE tt.tournament_id = $1::uuid`, tournamentID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var (
			teamID, pname, cls string
		)
		if err := rows.Scan(&teamID, &pname, &cls); err != nil {
			rows.Close()
			return nil, err
		}
		for i := range teams {
			if teams[i].info.ID == teamID {
				teams[i].info.Players = append(teams[i].info.Players, domain.TeamPlayer{Name: pname, Cls: cls})
				break
			}
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// urut players by kelas (A+ A B+ B C+ C)
	for i := range teams {
		sort.Slice(teams[i].info.Players, func(a, b int) bool {
			return clsOrder(teams[i].info.Players[a].Cls) < clsOrder(teams[i].info.Players[b].Cls)
		})
		teams[i].info.ID = fmt.Sprintf("t%d", teams[i].seed)
		snap.Teams = append(snap.Teams, teams[i].info)
	}

	// matches + games
	rows, err = s.pool.Query(ctx, `
		SELECT tm.match_key, tm.phase, tm.match_order,
		       ta.seed, tb.seed, tm.id::text
		FROM tournament_team_matches tm
		LEFT JOIN tournament_teams ta ON ta.id = tm.team_a_id
		LEFT JOIN tournament_teams tb ON tb.id = tm.team_b_id
		WHERE tm.tournament_id = $1::uuid
		ORDER BY tm.match_order`, tournamentID)
	if err != nil {
		return nil, err
	}
	matchID := map[string]int{} // internal match id → index di snap.Matches
	for rows.Next() {
		var (
			key, phase, internal string
			order                int
			seedA, seedB         *int
		)
		if err := rows.Scan(&key, &phase, &order, &seedA, &seedB, &internal); err != nil {
			rows.Close()
			return nil, err
		}
		m := domain.TeamMatch{
			ID:     key,
			Phase:  phase,
			Partai: []domain.TeamPartai{{}, {}, {}},
		}
		if seedA != nil {
			m.TeamA = fmt.Sprintf("t%d", *seedA)
		}
		if seedB != nil {
			m.TeamB = fmt.Sprintf("t%d", *seedB)
		}
		matchID[internal] = len(snap.Matches)
		snap.Matches = append(snap.Matches, m)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	rows, err = s.pool.Query(ctx, `
		SELECT tg.team_match_id::text, tg.partai_index, tg.score_a, tg.score_b
		FROM tournament_team_match_games tg
		JOIN tournament_team_matches tm ON tm.id = tg.team_match_id
		WHERE tm.tournament_id = $1::uuid
		ORDER BY tg.partai_index`, tournamentID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var (
			internal string
			idx       int
			a, b      *int
		)
		if err := rows.Scan(&internal, &idx, &a, &b); err != nil {
			rows.Close()
			return nil, err
		}
		if mi, ok := matchID[internal]; ok && idx >= 0 && idx < 3 {
			snap.Matches[mi].Partai[idx] = domain.TeamPartai{ScoreA: a, ScoreB: b}
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return snap, nil
}

// TeamSave — write-path tournament format team: validasi + transaksi
// (advisory lock, version check, upsert header, delete-reinsert tabel team,
// registrasi pemain). Pola sama dengan Save classic.
func (s *TournamentStore) TeamSave(ctx context.Context, id string, snap *domain.TeamTournamentSnapshot) (*domain.TeamTournamentSnapshot, error) {
	if id = strings.TrimSpace(id); id == "" {
		return nil, fmt.Errorf("%w: tournament id must not be blank", ErrValidation)
	}
	if err := domain.ValidateTeamTournament(snap); err != nil {
		return nil, fmt.Errorf("%w: %v", ErrValidation, err)
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

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

	// Upsert header (format team)
	if found {
		if _, err := tx.Exec(ctx, `
			UPDATE tournaments SET name = $2, event_date = $3::date, version = $4, format = 'team', updated_at = now()
			WHERE id = $1::uuid`, rowID, snap.Name, snap.Date, nextVersion); err != nil {
			return nil, err
		}
	} else {
		if err := tx.QueryRow(ctx, `
			INSERT INTO tournaments (share_code, name, event_date, version, format)
			VALUES ($1, $2, $3::date, $4, 'team')
			RETURNING id::text`, id, snap.Name, snap.Date, nextVersion).Scan(&rowID); err != nil {
			return nil, err
		}
	}

	// Registrasi pemain (auto-register — mirror resolve_tournament_player)
	playerIDs := map[string]string{} // normalized name → player_id
	for _, t := range snap.Teams {
		for _, p := range t.Players {
			norm := domain.NormalizePlayerName(p.Name)
			if _, ok := playerIDs[norm]; ok {
				continue
			}
			pid, ok, err := resolveTournamentPlayer(ctx, tx, p.Name)
			if err != nil {
				return nil, err
			}
			if ok {
				playerIDs[norm] = pid
			}
		}
	}

	// Delete-reinsert (matches dulu → teams)
	if _, err := tx.Exec(ctx, `DELETE FROM tournament_team_matches WHERE tournament_id = $1::uuid`, rowID); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM tournament_teams WHERE tournament_id = $1::uuid`, rowID); err != nil {
		return nil, err
	}

	teamInternal := map[string]string{} // "tN" → internal uuid
	for _, t := range snap.Teams {
		seed := seedOf(t.ID)
		var internal string
		if err := tx.QueryRow(ctx, `
			INSERT INTO tournament_teams (tournament_id, seed, team_name)
			VALUES ($1::uuid, $2, $3)
			RETURNING id::text`, rowID, seed, t.Name).Scan(&internal); err != nil {
			return nil, err
		}
		teamInternal[t.ID] = internal
		for _, p := range t.Players {
			norm := domain.NormalizePlayerName(p.Name)
			pid := playerIDs[norm]
			if _, err := tx.Exec(ctx, `
				INSERT INTO tournament_team_players (team_id, player_name, cls, player_id)
				VALUES ($1::uuid, $2, $3, $4::uuid)`,
				internal, p.Name, p.Cls, nilableString(pid)); err != nil {
				return nil, err
			}
		}
	}

	for i, m := range snap.Matches {
		var aID, bID *string
		if idA, ok := teamInternal[m.TeamA]; ok {
			aID = &idA
		}
		if idB, ok := teamInternal[m.TeamB]; ok {
			bID = &idB
		}
		matchKey := m.ID
		if matchKey == "" {
			matchKey = fmt.Sprintf("m-%d", i)
		}
		var matchInternal string
		if err := tx.QueryRow(ctx, `
			INSERT INTO tournament_team_matches
				(tournament_id, phase, match_order, match_key, team_a_id, team_b_id)
			VALUES ($1::uuid, $2, $3, $4, $5::uuid, $6::uuid)
			RETURNING id::text`,
			rowID, m.Phase, i, matchKey, aID, bID).Scan(&matchInternal); err != nil {
			return nil, err
		}
		for pi := 0; pi < 3 && pi < len(m.Partai); pi++ {
			pt := m.Partai[pi]
			if _, err := tx.Exec(ctx, `
				INSERT INTO tournament_team_match_games (team_match_id, partai_index, score_a, score_b)
				VALUES ($1::uuid, $2, $3, $4)`,
				matchInternal, pi, pt.ScoreA, pt.ScoreB); err != nil {
				return nil, err
			}
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	return s.TeamLoad(ctx, id)
}

// ── helpers ────────────────────────────────────────────────────────────────

// clsOrder — urutan kelas untuk sort (A+ A B+ B C+ C).
func clsOrder(cls string) int {
	switch cls {
	case "A+":
		return 0
	case "A":
		return 1
	case "B+":
		return 2
	case "B":
		return 3
	case "C+":
		return 4
	default:
		return 5 // C
	}
}

// seedOf — "tN" → N (1-based).
func seedOf(id string) int {
	var n int
	fmt.Sscanf(id, "t%d", &n)
	if n < 1 {
		return 1
	}
	if n > 6 {
		return 6
	}
	return n
}

// nilableString — string kosong → nil (untuk kolom nullable).
func nilableString(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
