package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
)

// ── Extractors (design §4.7): sumber → RawMatch list ──────────────────────
// PENTING: pgx melarang dua query bersamaan di satu tx/connection — setiap
// iterasi harus SELESAI membaca rows (dan menutupnya) sebelum query berikutnya.

// IngestSession — entry point ingest sesi (gate: status locked).
func (s *SessionStore) IngestSession(ctx context.Context, lookup string) (*IngestResult, error) {
	return s.ingest(ctx, lookup, s.extractSessionMatches)
}

// IngestTournament — entry point ingest tournament (classic | team otomatis
// via format column; gate: rating_sources.finalized).
func (s *SessionStore) IngestTournament(ctx context.Context, lookup string) (*IngestResult, error) {
	return s.ingest(ctx, lookup, s.extractTournamentMatches)
}

// ── Session ────────────────────────────────────────────────────────────────

type sessionGame struct {
	internalID string
	legacy     int
	slot       int
	court      int
	scoreA     int
	scoreB     bool // scored
	skipped    []string
}

func (s *SessionStore) extractSessionMatches(ctx context.Context, tx pgx.Tx, lookup string) ([]domain.RawMatch, *sourceMeta, error) {
	var (
		id, shareCode, title string
		dateStr              string
		createdAt            time.Time
		status               string
	)
	err := tx.QueryRow(ctx, `
		SELECT id::text, share_code, title, session_date::text, created_at, status
		FROM `+s.schema+`.sessions
		WHERE share_code = $1 OR id::text = $1
		ORDER BY (share_code = $1) DESC LIMIT 1`, lookup).
		Scan(&id, &shareCode, &title, &dateStr, &createdAt, &status)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}

	rows, err := tx.Query(ctx, `
		SELECT sg.internal_id::text, sg.legacy_order, sg.slot_index, sg.court_index,
		       coalesce(sg.score_a, 0), (sg.score_a IS NOT NULL AND sg.score_b IS NOT NULL),
		       COALESCE(sg.skipped_player_refs, '{}')
		FROM `+s.schema+`.scheduled_games sg
		WHERE sg.session_id = $1::uuid
		ORDER BY sg.legacy_order ASC`, id)
	if err != nil {
		return nil, nil, err
	}
	games := []sessionGame{}
	for rows.Next() {
		var g sessionGame
		var scored bool
		var skipped []string
		if err := rows.Scan(&g.internalID, &g.legacy, &g.slot, &g.court, &g.scoreA, &scored, &skipped); err != nil {
			rows.Close()
			return nil, nil, err
		}
		if skipped == nil {
			skipped = []string{}
		}
		g.skipped = skipped
		g.scoreB = scored
		if !scored {
			continue // belum dimainkan (skipped games are already unscored via clear)
		}
		games = append(games, g)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}

	matches := []domain.RawMatch{}
	for _, g := range games {
		var scoreA, scoreB int
		if err := tx.QueryRow(ctx, `
			SELECT score_a, score_b FROM `+s.schema+`.scheduled_games WHERE internal_id = $1::uuid`,
			g.internalID).Scan(&scoreA, &scoreB); err != nil {
			return nil, nil, err
		}

		// Build skipped set for this game (player_ref based, bebas any player)
		skippedSet := make(map[string]struct{}, len(g.skipped))
		for _, ref := range g.skipped {
			skippedSet[ref] = struct{}{}
		}
		prows, err := tx.Query(ctx, `
			SELECT sp.source_name, sp.is_absent, sp.player_ref, sgp.team, sgp.position
			FROM `+s.schema+`.scheduled_game_players sgp
			JOIN `+s.schema+`.session_players sp ON sp.internal_id = sgp.session_player_internal_id
			WHERE sgp.scheduled_game_internal_id = $1::uuid
			ORDER BY sgp.team, sgp.position`, g.internalID)
		if err != nil {
			return nil, nil, err
		}
		players := []domain.RawPlayer{}
		for prows.Next() {
			var name, team, playerRef string
			var absent bool
			var position int
			if err := prows.Scan(&name, &absent, &playerRef, &team, &position); err != nil {
				prows.Close()
				return nil, nil, err
			}
			// Per-game skipped overrides is_absent — skipped in this game = absent for rating
			if _, isSkipped := skippedSet[playerRef]; isSkipped {
				absent = true
			}
			players = append(players, domain.RawPlayer{
				Name:        name,
				Placeholder: domain.IsPlaceholderName(name),
				Team:        team,
				Position:    position,
				Absent:      absent,
			})
		}
		prows.Close()
		if err := prows.Err(); err != nil {
			return nil, nil, err
		}

		matches = append(matches, domain.RawMatch{
			StableGameID: fmt.Sprintf("legacy-%d", g.legacy),
			Date:         dateStr,
			Kind:         "session",
			SourceID:     shareCode,
			Title:        title,
			GameOrder:    fmt.Sprintf("%d-%d", g.slot, g.court),
			ScoreA:       scoreA,
			ScoreB:       scoreB,
			Target:       21,
			Phase:        "regular",
			Players:      players,
		})
	}

	fp, err := domain.SourceFingerprint(matches)
	if err != nil {
		return nil, nil, err
	}
	meta := &sourceMeta{
		Kind:        "session",
		SourceID:    shareCode,
		Date:        dateStr,
		CreatedAt:   createdAt,
		Fingerprint: fp,
		Final:       status != "draft",
		Title:       title,
	}
	return matches, meta, nil
}

// ── Tournament (classic | team, otomatis via format) ───────────────────────

func (s *SessionStore) extractTournamentMatches(ctx context.Context, tx pgx.Tx, lookup string) ([]domain.RawMatch, *sourceMeta, error) {
	var (
		id, shareCode, name, format string
		dateStr                     string
		createdAt                   time.Time
	)
	err := tx.QueryRow(ctx, `
		SELECT id::text, share_code, name, event_date::text, format, created_at
		FROM `+s.schema+`.tournaments
		WHERE share_code = $1 OR id::text = $1
		ORDER BY (share_code = $1) DESC LIMIT 1`, lookup).
		Scan(&id, &shareCode, &name, &dateStr, &format, &createdAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}

	// Gate: tournament hanya ingest saat finalized (rating_sources.finalized).
	finalized := false
	err = tx.QueryRow(ctx, `SELECT finalized FROM `+s.schema+`.rating_sources WHERE source_id = $1`, shareCode).Scan(&finalized)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, nil, err
	}

	var matches []domain.RawMatch
	if format == "team" {
		matches, err = s.extractTeamMatches(ctx, tx, id, shareCode, name, dateStr)
	} else {
		matches, err = s.extractClassicMatches(ctx, tx, id, shareCode, name, dateStr)
	}
	if err != nil {
		return nil, nil, err
	}

	fp, err := domain.SourceFingerprint(matches)
	if err != nil {
		return nil, nil, err
	}
	kind := "tournament_classic"
	if format == "team" {
		kind = "tournament_team"
	}
	meta := &sourceMeta{
		Kind:        kind,
		SourceID:    shareCode,
		Date:        dateStr,
		CreatedAt:   createdAt,
		Fingerprint: fp,
		Final:       finalized,
		Title:       name,
	}
	return matches, meta, nil
}

// ── Classic tournament ─────────────────────────────────────────────────────

type classicMatch struct {
	matchKey string
	phase    string
	scoreA   int
	scoreB   int
	pairA    string // pair internal id
	pairB    string
}

func (s *SessionStore) extractClassicMatches(ctx context.Context, tx pgx.Tx, tournamentID, shareCode, name, dateStr string) ([]domain.RawMatch, error) {
	rows, err := tx.Query(ctx, `
		SELECT tm.match_key, tm.phase, coalesce(tm.score_a, 0), coalesce(tm.score_b, 0),
		       (tm.score_a IS NOT NULL AND tm.score_b IS NOT NULL) AS scored,
		       coalesce(tp.id::text, ''), coalesce(tq.id::text, '')
		FROM `+s.schema+`.tournament_matches tm
		LEFT JOIN `+s.schema+`.tournament_pairs tp ON tp.id = tm.pair_a_id
		LEFT JOIN `+s.schema+`.tournament_pairs tq ON tq.id = tm.pair_b_id
		WHERE tm.tournament_id = $1::uuid
		ORDER BY tm.match_key`, tournamentID)
	if err != nil {
		return nil, err
	}
	matches := []classicMatch{}
	for rows.Next() {
		var m classicMatch
		var scored bool
		var pairA, pairB string
		if err := rows.Scan(&m.matchKey, &m.phase, &m.scoreA, &m.scoreB, &scored, &pairA, &pairB); err != nil {
			rows.Close()
			return nil, err
		}
		if !scored || pairA == "" || pairB == "" {
			continue
		}
		m.pairA = pairA
		m.pairB = pairB
		matches = append(matches, m)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	out := []domain.RawMatch{}
	for _, m := range matches {
		players := []domain.RawPlayer{}
		for _, pair := range []struct {
			id   string
			team string
		}{{m.pairA, "A"}, {m.pairB, "B"}} {
			prows, err := tx.Query(ctx, `
				SELECT p.canonical_name
				FROM `+s.schema+`.tournament_pair_players tpp
				JOIN `+s.schema+`.players p ON p.id = tpp.player_id
				WHERE tpp.pair_id = $1::uuid`, pair.id)
			if err != nil {
				return nil, err
			}
			for prows.Next() {
				var nm string
				if err := prows.Scan(&nm); err != nil {
					prows.Close()
					return nil, err
				}
				players = append(players, domain.RawPlayer{
					Name:        nm,
					Placeholder: domain.IsPlaceholderName(nm),
					Team:        pair.team,
				})
			}
			prows.Close()
			if err := prows.Err(); err != nil {
				return nil, err
			}
		}
		out = append(out, domain.RawMatch{
			StableGameID: m.matchKey,
			Date:         dateStr,
			Kind:         "tournament_classic",
			SourceID:     shareCode,
			Title:        name,
			GameOrder:    m.matchKey,
			ScoreA:       m.scoreA,
			ScoreB:       m.scoreB,
			Target:       21,
			Phase:        m.phase,
			Players:      players,
		})
	}
	return out, nil
}

// ── Team tournament ────────────────────────────────────────────────────────
// Tiap partai (0..2) = satu RawMatch dengan positional pairing:
//   partai 0: C+&C vs C+&C (position 0 = C+, position 1 = C)
//   partai 1: A+&A vs A+&A
//   partai 2: B+&B vs B+&B
// Target: 30 (group) / 42 (final).

var partaiClasses = [3][2]string{{"C+", "C"}, {"A+", "A"}, {"B+", "B"}}

type teamMatchRow struct {
	matchKey string
	phase    string
	teamA    string
	teamB    string
}

type teamPartaiRow struct {
	idx            int
	scoreA, scoreB int
	scored         bool
}

func (s *SessionStore) extractTeamMatches(ctx context.Context, tx pgx.Tx, tournamentID, shareCode, name, dateStr string) ([]domain.RawMatch, error) {
	rows, err := tx.Query(ctx, `
		SELECT tm.match_key, tm.phase, coalesce(tm.team_a_id::text, ''), coalesce(tm.team_b_id::text, '')
		FROM `+s.schema+`.tournament_team_matches tm
		WHERE tm.tournament_id = $1::uuid
		ORDER BY tm.match_order`, tournamentID)
	if err != nil {
		return nil, err
	}
	tms := []teamMatchRow{}
	for rows.Next() {
		var tm teamMatchRow
		if err := rows.Scan(&tm.matchKey, &tm.phase, &tm.teamA, &tm.teamB); err != nil {
			rows.Close()
			return nil, err
		}
		if tm.teamA == "" || tm.teamB == "" {
			continue
		}
		tms = append(tms, tm)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	out := []domain.RawMatch{}
	for _, tm := range tms {
		// partai games
		grows, err := tx.Query(ctx, `
			SELECT partai_index, coalesce(score_a, 0), coalesce(score_b, 0),
			       (score_a IS NOT NULL AND score_b IS NOT NULL)
			FROM `+s.schema+`.tournament_team_match_games
			WHERE team_match_id = (SELECT id FROM `+s.schema+`.tournament_team_matches
			                       WHERE match_key = $1 AND tournament_id = $2::uuid)
			ORDER BY partai_index`, tm.matchKey, tournamentID)
		if err != nil {
			return nil, err
		}
		partai := []teamPartaiRow{}
		for grows.Next() {
			var g teamPartaiRow
			if err := grows.Scan(&g.idx, &g.scoreA, &g.scoreB, &g.scored); err != nil {
				grows.Close()
				return nil, err
			}
			if !g.scored {
				continue
			}
			partai = append(partai, g)
		}
		grows.Close()
		if err := grows.Err(); err != nil {
			return nil, err
		}

		for _, g := range partai {
			players := []domain.RawPlayer{}
			for _, team := range []struct {
				id   string
				name string
			}{{tm.teamA, "A"}, {tm.teamB, "B"}} {
				prows, err := tx.Query(ctx, `
					SELECT player_name, cls
					FROM `+s.schema+`.tournament_team_players
					WHERE team_id = $1::uuid`, team.id)
				if err != nil {
					return nil, err
				}
				for prows.Next() {
					var nm, cls string
					if err := prows.Scan(&nm, &cls); err != nil {
						prows.Close()
						return nil, err
					}
					if !classInPartai(g.idx, cls) {
						continue
					}
					pos := 1
					if len(cls) > 0 && cls[len(cls)-1] == '+' {
						pos = 0
					}
					players = append(players, domain.RawPlayer{
						Name:        nm,
						Placeholder: domain.IsPlaceholderName(nm),
						Team:        team.name,
						Position:    pos,
					})
				}
				prows.Close()
				if err := prows.Err(); err != nil {
					return nil, err
				}
			}

			target := 30
			if tm.phase == "final" {
				target = 42
			}
			out = append(out, domain.RawMatch{
				StableGameID: fmt.Sprintf("%s-%d", tm.matchKey, g.idx),
				Date:         dateStr,
				Kind:         "tournament_team",
				SourceID:     shareCode,
				Title:        name,
				GameOrder:    fmt.Sprintf("%s-%d", tm.matchKey, g.idx),
				ScoreA:       g.scoreA,
				ScoreB:       g.scoreB,
				Target:       target,
				Phase:        tm.phase,
				Players:      players,
			})
		}
	}
	return out, nil
}

// classInPartai — apakah kelas pemain termasuk partai ini (partai 0: C+/C,
// partai 1: A+/A, partai 2: B+/B).
func classInPartai(partaiIdx int, cls string) bool {
	if partaiIdx < 0 || partaiIdx >= len(partaiClasses) {
		return false
	}
	for _, c := range partaiClasses[partaiIdx] {
		if cls == c {
			return true
		}
	}
	return false
}
