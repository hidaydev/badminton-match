package store

import (
	"context"
	"encoding/json"
	"errors"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ── Tipe output statistik (kontrak JSON frontend — sama persis dengan
// bm.get_player_stats_compat) ─────────────────────────────────────────────

type sessionStat struct {
	ID     string `json:"id"`
	Date   string `json:"date"`
	Title  string `json:"title"`
	Absent bool   `json:"absent"`
}

type statEntry struct {
	Name   string `json:"name"`
	Count  int    `json:"count"`
	Wins   int    `json:"wins"`
	Losses int    `json:"losses"`
}

type tournamentEntry struct {
	Name   string `json:"name"`
	Date   string `json:"date"`
	Games  int    `json:"games"`
	Wins   int    `json:"wins"`
	Losses int    `json:"losses"`
}

type tournamentEntrySmall struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
	Wins  int    `json:"wins"`
}

type playerStatsJSON struct {
	Name            string              `json:"name"`
	GamesPlayed     int                 `json:"gamesPlayed"`
	Wins            int                 `json:"wins"`
	Losses          int                 `json:"losses"`
	PointsFor       int                 `json:"pointsFor"`
	PointsAgainst   int                 `json:"pointsAgainst"`
	Sessions        []sessionStat       `json:"sessions"`
	TopPartners     []statEntry         `json:"topPartners"`
	TopOpponents    []statEntry         `json:"topOpponents"`
	TournamentStats tournamentStatsJSON `json:"tournamentStats"`
}

type tournamentStatsJSON struct {
	GamesPlayed  int                    `json:"gamesPlayed"`
	Wins         int                    `json:"wins"`
	Losses       int                    `json:"losses"`
	Tournaments  []tournamentEntry      `json:"tournaments"`
	TopPartners  []tournamentEntrySmall `json:"topPartners"`
	TopOpponents []tournamentEntrySmall `json:"topOpponents"`
}

// computePlayerStats — port bm.get_player_stats_compat (SQL → Go).
// Pemain tidak dikenal → statistik nol dengan name = nama yang dicari.
func computePlayerStats(ctx context.Context, pool *pgxpool.Pool, name string) ([]byte, error) {
	out := playerStatsJSON{
		Name:         name,
		Sessions:     []sessionStat{},
		TopPartners:  []statEntry{},
		TopOpponents: []statEntry{},
		TournamentStats: tournamentStatsJSON{
			Tournaments:  []tournamentEntry{},
			TopPartners:  []tournamentEntrySmall{},
			TopOpponents: []tournamentEntrySmall{},
		},
	}

	// Resolve player (alias → player). Mirror awal get_player_stats_compat.
	var playerID, canonical string
	err := pool.QueryRow(ctx, `
		SELECT p.id::text, p.canonical_name
		FROM player_aliases pa
		JOIN players p ON p.id = pa.player_id
		WHERE pa.alias_name = $1
		LIMIT 1`, domain.NormalizePlayerName(name)).Scan(&playerID, &canonical)
	if errors.Is(err, pgx.ErrNoRows) {
		return json.Marshal(out) // pemain tak dikenal → statistik kosong
	}
	if err != nil {
		return nil, err
	}
	out.Name = canonical

	// ── session stats (mirror base_stats) ────────────────────────────────
	// Game VOID (memuat ≥1 pemain is_absent) tidak dihitung — lihat
	// ABSENT_TBD_PLAYERS_DESIGN.md §4. Predikat sama untuk semua query stats.
	if err := pool.QueryRow(ctx, `
		SELECT
			count(*)::integer,
			coalesce(sum(CASE WHEN sg.score_a IS NULL OR sg.score_b IS NULL THEN 0
				WHEN sgp.team = 'A' AND sg.score_a > sg.score_b THEN 1
				WHEN sgp.team = 'B' AND sg.score_b > sg.score_a THEN 1 ELSE 0 END), 0)::integer,
			coalesce(sum(CASE WHEN sg.score_a IS NULL OR sg.score_b IS NULL THEN 0
				WHEN sgp.team = 'A' AND sg.score_a < sg.score_b THEN 1
				WHEN sgp.team = 'B' AND sg.score_b < sg.score_a THEN 1 ELSE 0 END), 0)::integer,
			coalesce(sum(CASE WHEN sg.score_a IS NULL OR sg.score_b IS NULL THEN 0
				WHEN sgp.team = 'A' THEN sg.score_a ELSE sg.score_b END), 0)::integer,
			coalesce(sum(CASE WHEN sg.score_a IS NULL OR sg.score_b IS NULL THEN 0
				WHEN sgp.team = 'A' THEN sg.score_b ELSE sg.score_a END), 0)::integer
		FROM session_players sp
		JOIN scheduled_game_players sgp ON sgp.session_player_internal_id = sp.internal_id
		JOIN scheduled_games sg ON sg.internal_id = sgp.scheduled_game_internal_id AND sg.session_id = sp.session_id
		WHERE sp.player_id = $1::uuid
		  AND NOT EXISTS (
			SELECT 1
			FROM scheduled_game_players sgpv
			JOIN session_players spv ON spv.internal_id = sgpv.session_player_internal_id
				AND spv.session_id = sg.session_id
			LEFT JOIN players pv ON pv.id = spv.player_id
			WHERE sgpv.scheduled_game_internal_id = sg.internal_id
			  AND (spv.is_absent = true OR spv.player_id IS NULL
			       OR pv.canonical_name ~* '^(free|tbd|default|xxx|unknown|kosong|belum ada)( [0-9]+)?$|\?+$')
		  )`,
		playerID).
		Scan(&out.GamesPlayed, &out.Wins, &out.Losses, &out.PointsFor, &out.PointsAgainst); err != nil {
		return nil, err
	}

	// ── sessions (mirror session_rows) ───────────────────────────────────
	rows, err := pool.Query(ctx, `
		SELECT s.id::text, s.session_date::text, s.title, sp.is_absent
		FROM session_players sp
		JOIN sessions s ON s.id = sp.session_id
		WHERE sp.player_id = $1::uuid
		ORDER BY s.session_date DESC`, playerID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var st sessionStat
		if err := rows.Scan(&st.ID, &st.Date, &st.Title, &st.Absent); err != nil {
			rows.Close()
			return nil, err
		}
		out.Sessions = append(out.Sessions, st)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// ── top partners (mirror partner_rows) ───────────────────────────────
	if out.TopPartners, err = loadStatEntries(ctx, pool, playerID, false); err != nil {
		return nil, err
	}
	// ── top opponents (mirror opponent_rows) ─────────────────────────────
	if out.TopOpponents, err = loadStatEntries(ctx, pool, playerID, true); err != nil {
		return nil, err
	}

	// ── tournament stats (mirror player_matches + t_base + t_tournaments) ─
	tr, err := loadTournamentStats(ctx, pool, playerID)
	if err != nil {
		return nil, err
	}
	out.TournamentStats = tr

	return json.Marshal(out)
}

// loadStatEntries — top-5 partner (opponent=false) atau lawan (opponent=true).
// Port dari CTE partner_rows / opponent_rows di get_player_stats_compat.
func loadStatEntries(ctx context.Context, pool *pgxpool.Pool, playerID string, opponent bool) ([]statEntry, error) {
	joinCond := "tl.team = sgp.team AND tl.session_player_internal_id <> sp.internal_id"
	if opponent {
		joinCond = "tl.team <> sgp.team"
	}
	query := `
		SELECT partner.canonical_name,
		       count(*)::integer,
		       coalesce(sum(CASE WHEN sg.score_a IS NULL OR sg.score_b IS NULL THEN 0
				WHEN sgp.team = 'A' AND sg.score_a > sg.score_b THEN 1
				WHEN sgp.team = 'B' AND sg.score_b > sg.score_a THEN 1 ELSE 0 END), 0)::integer,
		       coalesce(sum(CASE WHEN sg.score_a IS NULL OR sg.score_b IS NULL THEN 0
				WHEN sgp.team = 'A' AND sg.score_a < sg.score_b THEN 1
				WHEN sgp.team = 'B' AND sg.score_b < sg.score_a THEN 1 ELSE 0 END), 0)::integer
		FROM session_players sp
		JOIN scheduled_game_players sgp ON sgp.session_player_internal_id = sp.internal_id
		JOIN scheduled_games sg ON sg.internal_id = sgp.scheduled_game_internal_id AND sg.session_id = sp.session_id
		JOIN scheduled_game_players tl ON tl.scheduled_game_internal_id = sg.internal_id AND ` + joinCond + `
		JOIN session_players tsp ON tsp.internal_id = tl.session_player_internal_id AND tsp.session_id = sg.session_id
		JOIN players partner ON partner.id = tsp.player_id
		WHERE sp.player_id = $1::uuid
		  AND NOT EXISTS (
			SELECT 1
			FROM scheduled_game_players sgpv
			JOIN session_players spv ON spv.internal_id = sgpv.session_player_internal_id
				AND spv.session_id = sg.session_id
			LEFT JOIN players pv ON pv.id = spv.player_id
			WHERE sgpv.scheduled_game_internal_id = sg.internal_id
			  AND (spv.is_absent = true OR spv.player_id IS NULL
			       OR pv.canonical_name ~* '^(free|tbd|default|xxx|unknown|kosong|belum ada)( [0-9]+)?$|\?+$')
		  )
		GROUP BY partner.canonical_name
		ORDER BY count(*) DESC, lower(partner.canonical_name)
		LIMIT 5`
	rows, err := pool.Query(ctx, query, playerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []statEntry{}
	for rows.Next() {
		var e statEntry
		if err := rows.Scan(&e.Name, &e.Count, &e.Wins, &e.Losses); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// loadTournamentStats — port CTE t_base, t_tournaments, t_partner_rows,
// t_opponent_rows dari get_player_stats_compat.
func loadTournamentStats(ctx context.Context, pool *pgxpool.Pool, playerID string) (tournamentStatsJSON, error) {
	out := tournamentStatsJSON{
		Tournaments:  []tournamentEntry{},
		TopPartners:  []tournamentEntrySmall{},
		TopOpponents: []tournamentEntrySmall{},
	}

	type tMatch struct {
		mySide string // 'A' | 'B'
		scoreA int
		scoreB int
		name   string
		date   string
	}
	matches := []tMatch{}
	rows, err := pool.Query(ctx, `
		SELECT t.name, t.event_date::text, tm.score_a, tm.score_b,
		       tm.pair_a_id::text, tm.pair_b_id::text, tpp.pair_id::text
		FROM tournament_pair_players tpp
		JOIN tournament_pairs tp ON tp.id = tpp.pair_id
		JOIN tournament_matches tm ON (tm.pair_a_id = tpp.pair_id OR tm.pair_b_id = tpp.pair_id)
			AND tm.tournament_id = tp.tournament_id
		JOIN tournaments t ON t.id = tm.tournament_id
		WHERE tpp.player_id = $1::uuid
		  AND tm.score_a IS NOT NULL AND tm.score_b IS NOT NULL`, playerID)
	if err != nil {
		return out, err
	}
	for rows.Next() {
		var (
			m                    tMatch
			pairA, pairB, myPair string
		)
		if err := rows.Scan(&m.name, &m.date, &m.scoreA, &m.scoreB, &pairA, &pairB, &myPair); err != nil {
			rows.Close()
			return out, err
		}
		if pairA == myPair {
			m.mySide = "A"
		} else {
			m.mySide = "B"
		}
		matches = append(matches, m)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return out, err
	}

	// t_base + t_tournaments
	tournMap := map[string]*tournamentEntry{}
	for _, m := range matches {
		win := (m.mySide == "A" && m.scoreA > m.scoreB) || (m.mySide == "B" && m.scoreB > m.scoreA)
		loss := (m.mySide == "A" && m.scoreA < m.scoreB) || (m.mySide == "B" && m.scoreB < m.scoreA)
		out.GamesPlayed++
		if win {
			out.Wins++
		}
		if loss {
			out.Losses++
		}
		key := m.name + "\x00" + m.date
		te, ok := tournMap[key]
		if !ok {
			te = &tournamentEntry{Name: m.name, Date: m.date}
			tournMap[key] = te
		}
		te.Games++
		if win {
			te.Wins++
		}
		if loss {
			te.Losses++
		}
	}
	// order by date desc (mirror jsonb_agg(... order by tt.date desc))
	for _, te := range tournMap {
		out.Tournaments = append(out.Tournaments, *te)
	}
	sortTournaments(out.Tournaments)

	// t_partner_rows / t_opponent_rows
	if out.TopPartners, err = loadTournamentEntries(ctx, pool, playerID, false); err != nil {
		return out, err
	}
	if out.TopOpponents, err = loadTournamentEntries(ctx, pool, playerID, true); err != nil {
		return out, err
	}
	return out, nil
}

// loadTournamentEntries — top-5 partner/lawan tournament (port t_partner_rows
// / t_opponent_rows).
func loadTournamentEntries(ctx context.Context, pool *pgxpool.Pool, playerID string, opponent bool) ([]tournamentEntrySmall, error) {
	joinCond := "tpp2.pair_id = tpp.pair_id AND tpp2.player_id <> tpp.player_id"
	if opponent {
		joinCond = `tpp2.pair_id = CASE WHEN tm.pair_a_id = tpp.pair_id THEN tm.pair_b_id ELSE tm.pair_a_id END
		     AND tpp2.player_id <> tpp.player_id`
	}
	query := `
		SELECT other.canonical_name,
		       count(DISTINCT tm.id)::integer,
		       coalesce(sum(CASE WHEN tm.score_a IS NULL OR tm.score_b IS NULL THEN 0
				WHEN tpp.pair_id = tm.pair_a_id AND tm.score_a > tm.score_b THEN 1
				WHEN tpp.pair_id = tm.pair_b_id AND tm.score_b > tm.score_a THEN 1 ELSE 0 END), 0)::integer
		FROM tournament_pair_players tpp
		JOIN tournament_pairs tp ON tp.id = tpp.pair_id
		JOIN tournament_matches tm ON (tm.pair_a_id = tpp.pair_id OR tm.pair_b_id = tpp.pair_id)
			AND tm.tournament_id = tp.tournament_id
		JOIN tournament_pair_players tpp2 ON ` + joinCond + `
		JOIN players other ON other.id = tpp2.player_id
		WHERE tpp.player_id = $1::uuid
		  AND tm.score_a IS NOT NULL AND tm.score_b IS NOT NULL
		GROUP BY other.canonical_name
		ORDER BY count(DISTINCT tm.id) DESC, lower(other.canonical_name)
		LIMIT 5`
	rows, err := pool.Query(ctx, query, playerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []tournamentEntrySmall{}
	for rows.Next() {
		var e tournamentEntrySmall
		if err := rows.Scan(&e.Name, &e.Count, &e.Wins); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// sortTournaments — urutkan by date desc, tie-break stabil (nama) supaya output
// deterministik (mirror order by tt.date desc).
func sortTournaments(ts []tournamentEntry) {
	for i := 1; i < len(ts); i++ {
		for j := i; j > 0; j-- {
			if ts[j].Date > ts[j-1].Date {
				ts[j], ts[j-1] = ts[j-1], ts[j]
			}
		}
	}
}
