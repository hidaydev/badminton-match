package store

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ── Tipe output statistik (kontrak JSON frontend — sama persis dengan
// bm.get_player_stats_compat) ─────────────────────────────────────────────

type sessionStat struct {
	ID string `json:"id"`
	// ShareCode — kunci yang menghubungkan sesi ini dengan entri ranking poin
	// (rating_events.source_id = sessions.share_code). Dipakai halaman pemain
	// untuk menandai sesi mana yang masuk perhitungan poin.
	ShareCode string `json:"share_code"`
	Date      string `json:"date"`
	Title     string `json:"title"`
	Absent    bool   `json:"absent"`
}

type statEntry struct {
	Name   string `json:"name"`
	Count  int    `json:"count"`
	Wins   int    `json:"wins"`
	Losses int    `json:"losses"`
}

type tournamentEntry struct {
	Name string `json:"name"`
	// ShareCode — kunci penghubung ke entri ranking poin (rating_events.source_id
	// = tournaments.share_code). Dipakai halaman pemain untuk menandai turnamen
	// mana yang masuk perhitungan poin.
	ShareCode string `json:"share_code"`
	Date      string `json:"date"`
	Games     int    `json:"games"`
	Wins      int    `json:"wins"`
	Losses    int    `json:"losses"`
}

type tournamentEntrySmall struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
	Wins  int    `json:"wins"`
}

type playerStatsJSON struct {
	Name            string              `json:"name"`
	PlayerID        string              `json:"playerId"`
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
	out.PlayerID = playerID

	// ── session stats (mirror base_stats) ────────────────────────────────
	// SkipPlayer: cuma game dimana si pemain sendiri absent/skipped/placeholder yang di-exclude,
	// bukan void seluruh game kalo ada orang lain absent (samain dengan rating AbsentSkipPlayer).
	// Lihat rating_extract.go per-game skipped.
	// Game tanpa skor (belum dimainkan / sengaja di-skip semua pemainnya) TIDAK
	// dihitung — konsisten dengan rating engine yang mengabaikan game tak ber-skor.
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
		LEFT JOIN players p ON p.id = sp.player_id
		WHERE sp.player_id = $1::uuid
		  AND sp.is_absent = false
		  AND NOT (sp.player_ref = ANY(COALESCE(sg.skipped_player_refs,'{}')))
		  AND sg.score_a IS NOT NULL AND sg.score_b IS NOT NULL
		  AND (p.canonical_name IS NULL OR p.canonical_name !~* '^(free|tbd|default|xxx|unknown|kosong|belum ada)( [0-9]+)?$|^\?+$')`,
		playerID).
		Scan(&out.GamesPlayed, &out.Wins, &out.Losses, &out.PointsFor, &out.PointsAgainst); err != nil {
		return nil, err
	}

	// ── sessions (mirror session_rows) ───────────────────────────────────
	rows, err := pool.Query(ctx, `
		SELECT s.id::text, s.share_code, s.session_date::text, s.title, sp.is_absent
		FROM session_players sp
		JOIN sessions s ON s.id = sp.session_id
		WHERE sp.player_id = $1::uuid
		ORDER BY s.session_date DESC`, playerID)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var st sessionStat
		if err := rows.Scan(&st.ID, &st.ShareCode, &st.Date, &st.Title, &st.Absent); err != nil {
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

// loadStatEntries — top-3 partner (opponent=false) atau lawan (opponent=true).
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
		LEFT JOIN players pself ON pself.id = sp.player_id
		WHERE sp.player_id = $1::uuid
		  AND sp.is_absent = false
		  AND NOT (sp.player_ref = ANY(COALESCE(sg.skipped_player_refs,'{}')))
		  AND sg.score_a IS NOT NULL AND sg.score_b IS NOT NULL
		  AND (pself.canonical_name IS NULL OR pself.canonical_name !~* '^(free|tbd|default|xxx|unknown|kosong|belum ada)( [0-9]+)?$|^\?+$')
		GROUP BY partner.canonical_name
		ORDER BY count(*) DESC, lower(partner.canonical_name)
		LIMIT 3`
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

	matches := []playerTournamentMatch{}
	rows, err := pool.Query(ctx, `
		SELECT t.name, t.event_date::text, t.share_code, tm.score_a, tm.score_b,
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
			m                    playerTournamentMatch
			pairA, pairB, myPair string
		)
		if err := rows.Scan(&m.name, &m.date, &m.share, &m.scoreA, &m.scoreB, &pairA, &pairB, &myPair); err != nil {
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

	// Turnamen TIM: partai di mana kelas pemain ikut main (ClassInPartai).
	teamMatches, err := loadTeamTournamentMatches(ctx, pool, playerID)
	if err != nil {
		return out, err
	}
	matches = append(matches, teamMatches...)

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
		// Key per turnamen: share_code kalau ada (dua turnamen beda dengan nama
		// sama tidak tercampur); fallback nama+tanggal untuk data lama.
		key := m.share
		if key == "" {
			key = m.name + "\x00" + m.date
		}
		te, ok := tournMap[key]
		if !ok {
			te = &tournamentEntry{Name: m.name, Date: m.date, ShareCode: m.share}
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

// playerTournamentMatch — satu game turnamen (classic/team) yang dimainkan
// seorang pemain, dari sudut pandangnya ('A' | 'B'). Classic & team melewati
// agregasi yang sama.
type playerTournamentMatch struct {
	mySide string
	scoreA int
	scoreB int
	name   string
	date   string
	share  string // tournaments.share_code
}

// loadTeamTournamentMatches — game turnamen TIM untuk seorang pemain. Satu
// partai = satu game, tapi hanya partai yang kelasnya cocok (ClassInPartai)
// yang dihitung. Keputusan kelas→partai tetap di domain, tidak diduplikasi di SQL.
func loadTeamTournamentMatches(ctx context.Context, pool *pgxpool.Pool, playerID string) ([]playerTournamentMatch, error) {
	rows, err := pool.Query(ctx, `
		SELECT t.name, t.event_date::text, t.share_code,
		       ttp.cls, (tm.team_a_id = ttp.team_id) AS is_a,
		       tg.partai_index, tg.score_a, tg.score_b
		FROM tournament_team_players ttp
		JOIN tournament_teams tt ON tt.id = ttp.team_id
		JOIN tournaments t ON t.id = tt.tournament_id
		JOIN tournament_team_matches tm ON tm.tournament_id = t.id
			AND (tm.team_a_id = ttp.team_id OR tm.team_b_id = ttp.team_id)
		JOIN tournament_team_match_games tg ON tg.team_match_id = tm.id
		WHERE ttp.player_id = $1::uuid
		  AND tg.score_a IS NOT NULL AND tg.score_b IS NOT NULL`, playerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []playerTournamentMatch{}
	for rows.Next() {
		var (
			m         playerTournamentMatch
			cls       string
			isA       bool
			partaiIdx int
		)
		if err := rows.Scan(&m.name, &m.date, &m.share, &cls, &isA, &partaiIdx,
			&m.scoreA, &m.scoreB); err != nil {
			return nil, err
		}
		if !domain.ClassInPartai(partaiIdx, cls) {
			continue
		}
		if isA {
			m.mySide = "A"
		} else {
			m.mySide = "B"
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// tournamentEncounter — satu kemunculan rekan/lawan di satu game turnamen,
// ternormalisasi lintas format (classic & team) agar bisa diagregasi bersama.
type tournamentEncounter struct {
	name string
	win  bool
}

// loadTournamentEntries — top-3 partner/lawan turnamen (port t_partner_rows /
// t_opponent_rows), classic + team. Diagregasi di Go supaya pemain yang sama di
// classic DAN team tidak terpecah jadi dua baris.
func loadTournamentEntries(ctx context.Context, pool *pgxpool.Pool, playerID string, opponent bool) ([]tournamentEntrySmall, error) {
	classic, err := loadClassicTournamentEncounters(ctx, pool, playerID, opponent)
	if err != nil {
		return nil, err
	}
	team, err := loadTeamTournamentEncounters(ctx, pool, playerID, opponent)
	if err != nil {
		return nil, err
	}
	encounters := append(classic, team...)

	type agg struct{ count, wins int }
	byName := map[string]*agg{}
	order := []string{}
	for _, e := range encounters {
		a, ok := byName[e.name]
		if !ok {
			a = &agg{}
			byName[e.name] = a
			order = append(order, e.name)
		}
		a.count++
		if e.win {
			a.wins++
		}
	}
	out := make([]tournamentEntrySmall, 0, len(order))
	for _, n := range order {
		out = append(out, tournamentEntrySmall{Name: n, Count: byName[n].count, Wins: byName[n].wins})
	}
	// count desc, lalu nama (case-insensitive) — mirror "ORDER BY count(*) DESC,
	// lower(name)". Di Go supaya penggabungan classic+team ikut tersortir.
	sort.Slice(out, func(i, j int) bool {
		if out[i].Count != out[j].Count {
			return out[i].Count > out[j].Count
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	if len(out) > 3 {
		out = out[:3]
	}
	return out, nil
}

// loadClassicTournamentEncounters — rekan (pair_id sama) atau lawan (pair lawan)
// per match classic. Satu baris = satu match.
func loadClassicTournamentEncounters(ctx context.Context, pool *pgxpool.Pool, playerID string, opponent bool) ([]tournamentEncounter, error) {
	joinCond := "tpp2.pair_id = tpp.pair_id AND tpp2.player_id <> tpp.player_id"
	if opponent {
		joinCond = `tpp2.pair_id = CASE WHEN tm.pair_a_id = tpp.pair_id THEN tm.pair_b_id ELSE tm.pair_a_id END
		     AND tpp2.player_id <> tpp.player_id`
	}
	rows, err := pool.Query(ctx, `
		SELECT other.canonical_name,
		       (tpp.pair_id = tm.pair_a_id AND tm.score_a > tm.score_b)
		    OR (tpp.pair_id = tm.pair_b_id AND tm.score_b > tm.score_a)
		FROM tournament_pair_players tpp
		JOIN tournament_pairs tp ON tp.id = tpp.pair_id
		JOIN tournament_matches tm ON (tm.pair_a_id = tpp.pair_id OR tm.pair_b_id = tpp.pair_id)
			AND tm.tournament_id = tp.tournament_id
		JOIN tournament_pair_players tpp2 ON `+joinCond+`
		JOIN players other ON other.id = tpp2.player_id
		WHERE tpp.player_id = $1::uuid
		  AND tm.score_a IS NOT NULL AND tm.score_b IS NOT NULL`, playerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []tournamentEncounter{}
	for rows.Next() {
		var e tournamentEncounter
		if err := rows.Scan(&e.name, &e.win); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

// loadTeamTournamentEncounters — rekan/lawan per partai turnamen TIM. Satu baris
// = (game partai) × (pemain lawan/serekan). Sisi ganda ditentukan kelas→partai
// lewat domain.ClassInPartai, tidak diduplikasi di SQL: pada satu partai,
// rekan = anggota tim yang kelasnya satu grup, lawan = dua pemain tim lawan grup
// yang sama.
func loadTeamTournamentEncounters(ctx context.Context, pool *pgxpool.Pool, playerID string, opponent bool) ([]tournamentEncounter, error) {
	rows, err := pool.Query(ctx, `
		SELECT ttp.cls,
		       tg.partai_index,
		       CASE WHEN tm.team_a_id = ttp.team_id
		            THEN tg.score_a > tg.score_b
		            ELSE tg.score_b > tg.score_a END AS win,
		       (other.team_id = ttp.team_id) AS same_team,
		       other.cls,
		       COALESCE(p.canonical_name, other.player_name) AS other_name
		FROM tournament_team_players ttp
		JOIN tournament_teams tt ON tt.id = ttp.team_id
		JOIN tournament_team_matches tm ON tm.tournament_id = tt.tournament_id
			AND (tm.team_a_id = ttp.team_id OR tm.team_b_id = ttp.team_id)
		JOIN tournament_team_match_games tg ON tg.team_match_id = tm.id
			AND tg.score_a IS NOT NULL AND tg.score_b IS NOT NULL
		JOIN tournament_team_players other
			ON other.team_id IN (tm.team_a_id, tm.team_b_id)
			AND NOT (other.team_id = ttp.team_id AND other.cls = ttp.cls)
		LEFT JOIN players p ON p.id = other.player_id
		WHERE ttp.player_id = $1::uuid`, playerID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []tournamentEncounter{}
	for rows.Next() {
		var (
			myCls, otherCls, otherName string
			partaiIdx                  int
			win, sameTeam              bool
		)
		if err := rows.Scan(&myCls, &partaiIdx, &win, &sameTeam, &otherCls, &otherName); err != nil {
			return nil, err
		}
		if !domain.ClassInPartai(partaiIdx, myCls) {
			continue // pemain tak main di partai ini
		}
		if !domain.ClassInPartai(partaiIdx, otherCls) {
			continue // hanya grup partai yang sama yang relevan
		}
		// partner → butuh serekan (sameTeam); opponent → butuh tim lawan.
		if sameTeam == opponent {
			continue
		}
		out = append(out, tournamentEncounter{name: otherName, win: win})
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
