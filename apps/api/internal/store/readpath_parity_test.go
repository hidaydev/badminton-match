package store

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"testing"
	"time"

	"majadu-api/internal/db"
	"majadu-api/internal/domain"
)

// TestIntegrationReadPathParity — verifikasi read-path Go identik dengan fungsi
// SQL lama (get_session / list_sessions / list_players / get_player_stats).
// Berlaku SELAMA fungsi SQL masih ada; setelah 000004 (drop read-path
// functions), test ini di-skip otomatis.
func TestIntegrationReadPathParity(t *testing.T) {
	url := os.Getenv("MAJADU_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("MAJADU_TEST_DATABASE_URL not set — skipping integration test")
	}
	schema := os.Getenv("MAJADU_TEST_DB_SCHEMA")
	if schema == "" {
		schema = "bm_dev"
	}

	pool, err := db.NewPool(context.Background(), url, schema)
	if err != nil {
		t.Fatalf("db connect: %v", err)
	}
	defer pool.Close()
	ctx := context.Background()

	// Skip bila fungsi SQL read-path sudah di-drop (pasca 000004).
	var reg *string
	if err := pool.QueryRow(ctx,
		`SELECT to_regprocedure('get_session(text)')::text`).Scan(&reg); err != nil {
		t.Fatalf("check function: %v", err)
	}
	if reg == nil {
		t.Skip("get_session sudah di-drop — read-path Go sudah satu-satunya")
	}

	st := NewSessionStore(pool, schema)
	ps := NewPlayerStore(pool)

	players := []domain.Player{
		{ID: "par1", Name: "Par One", Gender: "M", Tier: 1},
		{ID: "par2", Name: "Par Two", Gender: "F", Tier: 2},
		{ID: "par3", Name: "Par Three", Gender: "M", Tier: 3},
		{ID: "par4", Name: "Par Four", Gender: "M", Tier: 4},
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}

	// ── buat session lengkap: fix match, absent, played + scores ────────
	id := "it-parity-" + fmt.Sprintf("%d", time.Now().UnixNano())
	empty1 := "par1"
	empty2 := "par2"
	snap := &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "Parity", Date: "2026-08-13", Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: len(players),
			CourtNames:  []string{"C1"},
		},
		Players:       players,
		FixMatches:    []domain.FixMatch{{ID: "f1", Slots: [4]*string{&empty1, &empty2, nil, nil}}},
		Schedule:      []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"par1", "par2"}, TeamB: [2]string{"par3", "par4"}}},
		PlayedGames:   []string{"0-0"},
		GameScores:    map[string]domain.GameScore{"0-0": {A: 21, B: 18}},
		AbsentPlayers: []string{"par4"},
	}
	if _, err := st.Save(ctx, id, snap); err != nil {
		t.Fatalf("save: %v", err)
	}
	defer func() { _ = st.Delete(ctx, id) }()

	// ── parity: Load (Go) vs get_session (SQL) ───────────────────────────
	goSnap, err := st.Load(ctx, id)
	if err != nil {
		t.Fatalf("go load: %v", err)
	}
	var sqlRaw []byte
	if err := pool.QueryRow(ctx, `SELECT get_session($1)`, id).Scan(&sqlRaw); err != nil {
		t.Fatalf("sql get_session: %v", err)
	}
	sqlSnap := &domain.CloudSnapshot{}
	if err := json.Unmarshal(sqlRaw, sqlSnap); err != nil {
		t.Fatalf("decode sql snapshot: %v", err)
	}
	if !reflect.DeepEqual(goSnap, sqlSnap) {
		gb, _ := json.Marshal(goSnap)
		sb, _ := json.Marshal(sqlSnap)
		t.Fatalf("LOAD PARITY MISMATCH\nGO : %s\nSQL: %s", gb, sb)
	}

	// ── parity: ListSessions (Go) vs list_sessions (SQL) ─────────────────
	goList, err := st.ListSessions(ctx)
	if err != nil {
		t.Fatalf("go list: %v", err)
	}
	sqlListRaw, err := pool.Query(ctx, `SELECT id, title, date, player_count, total_games, locked FROM list_sessions()`)
	if err != nil {
		t.Fatalf("sql list_sessions: %v", err)
	}
	sqlList := []SessionMeta{}
	for sqlListRaw.Next() {
		var m SessionMeta
		if err := sqlListRaw.Scan(&m.ID, &m.Title, &m.Date, &m.PlayerCount, &m.TotalGames, &m.Locked); err != nil {
			t.Fatalf("scan sql list: %v", err)
		}
		sqlList = append(sqlList, m)
	}
	sqlListRaw.Close()
	if !reflect.DeepEqual(goList, sqlList) {
		t.Fatalf("LIST SESSIONS PARITY MISMATCH\nGO : %+v\nSQL: %+v", goList, sqlList)
	}

	// ── parity: list players ─────────────────────────────────────────────
	goPlayers, err := ps.List(ctx)
	if err != nil {
		t.Fatalf("go players: %v", err)
	}
	sqlPlayersRaw, err := pool.Query(ctx, `SELECT name, gender, tier FROM list_players()`)
	if err != nil {
		t.Fatalf("sql list_players: %v", err)
	}
	sqlPlayers := []PlayerSummary{}
	for sqlPlayersRaw.Next() {
		var p PlayerSummary
		if err := sqlPlayersRaw.Scan(&p.Name, &p.Gender, &p.Tier); err != nil {
			t.Fatalf("scan sql players: %v", err)
		}
		sqlPlayers = append(sqlPlayers, p)
	}
	sqlPlayersRaw.Close()
	if !reflect.DeepEqual(goPlayers, sqlPlayers) {
		t.Fatalf("LIST PLAYERS PARITY MISMATCH\nGO : %+v\nSQL: %+v", goPlayers, sqlPlayers)
	}

	// ── parity: player stats (per pemain) ────────────────────────────────
	for _, p := range players {
		goStats, err := ps.Stats(ctx, p.Name)
		if err != nil {
			t.Fatalf("go stats %s: %v", p.Name, err)
		}
		var sqlStats []byte
		if err := pool.QueryRow(ctx, `SELECT get_player_stats($1)`, p.Name).Scan(&sqlStats); err != nil {
			t.Fatalf("sql stats %s: %v", p.Name, err)
		}
		var goM, sqlM any
		if err := json.Unmarshal(goStats, &goM); err != nil {
			t.Fatalf("decode go stats: %v", err)
		}
		if err := json.Unmarshal(sqlStats, &sqlM); err != nil {
			t.Fatalf("decode sql stats: %v", err)
		}
		if !reflect.DeepEqual(goM, sqlM) {
			t.Fatalf("STATS PARITY MISMATCH (%s)\nGO : %s\nSQL: %s", p.Name, goStats, sqlStats)
		}
	}
}
