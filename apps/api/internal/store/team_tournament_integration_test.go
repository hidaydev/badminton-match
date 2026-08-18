package store

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"majadu-api/internal/db"
	"majadu-api/internal/domain"
)

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// buildTeamSnapIT — snapshot team valid untuk integration test.
func buildTeamSnapIT() *domain.TeamTournamentSnapshot {
	classes := []string{"A+", "A", "B+", "B", "C+", "C"}
	teams := make([]domain.TeamInfo, 0, 6)
	for i := 0; i < 6; i++ {
		players := make([]domain.TeamPlayer, 0, 6)
		for _, c := range classes {
			players = append(players, domain.TeamPlayer{
				Name: fmt.Sprintf("T%d-%s-%d", i+1, c, time.Now().UnixNano()%100000),
				Cls:  c,
			})
		}
		teams = append(teams, domain.TeamInfo{
			ID:      fmt.Sprintf("t%d", i+1),
			Name:    fmt.Sprintf("Tim %d", i+1),
			Players: players,
		})
	}
	pairs := [][2]string{{"t1", "t2"}, {"t3", "t4"}, {"t5", "t6"}, {"t1", "t3"}, {"t2", "t5"}, {"t4", "t6"}, {"t1", "t4"}, {"t2", "t6"}, {"t3", "t5"}}
	matches := make([]domain.TeamMatch, 0, len(pairs)+1)
	for i, p := range pairs {
		matches = append(matches, domain.TeamMatch{
			ID:     fmt.Sprintf("g-%d", i+1),
			Phase:  "group",
			TeamA:  p[0],
			TeamB:  p[1],
			Partai: []domain.TeamPartai{{}, {}, {}},
		})
	}
	matches = append(matches, domain.TeamMatch{
		ID: "final", Phase: "final", TeamA: "t1", TeamB: "t2",
		Partai: []domain.TeamPartai{{}, {}, {}},
	})
	return &domain.TeamTournamentSnapshot{
		Format: "team", Name: "IT Team Cup", Date: "2026-08-20",
		Teams: teams, Matches: matches,
	}
}

// TestIntegrationTeamTournamentRoundTrip — create → load → update skor partai → list.
func TestIntegrationTeamTournamentRoundTrip(t *testing.T) {
	url := os.Getenv("MAJADU_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("MAJADU_TEST_DATABASE_URL not set — skipping integration test")
	}
	schema := os.Getenv("MAJADU_TEST_DB_SCHEMA")
	if schema == "" {
		schema = "bm_dev"
	}
	pool, err := db.NewPool(context.Background(), url, schema, discardLogger())
	if err != nil {
		t.Fatalf("db connect: %v", err)
	}
	defer pool.Close()
	ctx := context.Background()
	ts := NewTournamentStore(pool, schema)

	id := "it-team-" + fmt.Sprintf("%d", time.Now().UnixNano())

	// create
	created, err := ts.TeamSave(ctx, id, buildTeamSnapIT())
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if created.Version == nil || *created.Version != 1 {
		t.Fatalf("expected version 1, got %v", created.Version)
	}
	defer pool.Exec(ctx, `DELETE FROM tournaments WHERE share_code = $1`, id)

	// format + list
	format, err := ts.TournamentFormat(ctx, id)
	if err != nil || format != "team" {
		t.Fatalf("format = %q, err = %v", format, err)
	}
	metas, err := ts.List(ctx)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	found := false
	for _, m := range metas {
		if m.ID == id {
			found = true
			if m.Format != "team" {
				t.Fatalf("meta format = %q, want team", m.Format)
			}
		}
	}
	if !found {
		t.Fatal("team tournament tidak muncul di list")
	}

	// validasi struktur load
	if len(created.Teams) != 6 {
		t.Fatalf("teams = %d, want 6", len(created.Teams))
	}
	for _, tm := range created.Teams {
		if len(tm.Players) != 6 {
			t.Fatalf("team %s players = %d, want 6", tm.ID, len(tm.Players))
		}
		seen := map[string]bool{}
		for _, p := range tm.Players {
			if p.Name == "" || seen[p.Cls] {
				t.Fatalf("player invalid: %+v", p)
			}
			seen[p.Cls] = true
		}
	}
	if len(created.Matches) != 10 { // 9 grup + 1 final
		t.Fatalf("matches = %d, want 10", len(created.Matches))
	}

	// update: set skor partai match 1 (group, 30/28 & 29/30 & 30/25) + final (42/40)
	upd := buildTeamSnapIT()
	upd.Version = ptrInt(1)
	upd.Matches[0].Partai = []domain.TeamPartai{
		{ScoreA: ptrInt(30), ScoreB: ptrInt(28)},
		{ScoreA: ptrInt(29), ScoreB: ptrInt(30)},
		{ScoreA: ptrInt(30), ScoreB: ptrInt(25)},
	}
	upd.Matches[9].Partai = []domain.TeamPartai{
		{ScoreA: ptrInt(42), ScoreB: ptrInt(40)},
		{},
		{},
	}
	updated, err := ts.TeamSave(ctx, id, upd)
	if err != nil {
		t.Fatalf("update: %v", err)
	}
	if updated.Version == nil || *updated.Version != 2 {
		t.Fatalf("expected version 2, got %v", updated.Version)
	}
	g0 := updated.Matches[0]
	if g0.Partai[0].ScoreA == nil || *g0.Partai[0].ScoreA != 30 || *g0.Partai[0].ScoreB != 28 {
		t.Fatalf("partai 0 = %+v", g0.Partai[0])
	}
	f := updated.Matches[9]
	if f.Partai[0].ScoreA == nil || *f.Partai[0].ScoreA != 42 {
		t.Fatalf("final partai 0 = %+v", f.Partai[0])
	}

	// version mismatch → tolak
	stale := buildTeamSnapIT()
	stale.Version = ptrInt(99)
	if _, err := ts.TeamSave(ctx, id, stale); !errorsIs(err) {
		t.Fatalf("expected error, got %v", err)
	}
}

func TestIntegrationTeamTournamentRegisterPlayers(t *testing.T) {
	url := os.Getenv("MAJADU_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("MAJADU_TEST_DATABASE_URL not set — skipping integration test")
	}
	schema := os.Getenv("MAJADU_TEST_DB_SCHEMA")
	if schema == "" {
		schema = "bm_dev"
	}
	pool, err := db.NewPool(context.Background(), url, schema, discardLogger())
	if err != nil {
		t.Fatalf("db connect: %v", err)
	}
	defer pool.Close()
	ctx := context.Background()
	ts := NewTournamentStore(pool, schema)

	snap := buildTeamSnapIT()
	id := "it-team-reg-" + fmt.Sprintf("%d", time.Now().UnixNano())
	if _, err := ts.TeamSave(ctx, id, snap); err != nil {
		t.Fatalf("create: %v", err)
	}
	defer pool.Exec(ctx, `DELETE FROM tournaments WHERE share_code = $1`, id)

	// semua 36 nama pemain harus ter-register di players (via alias)
	var count int
	err = pool.QueryRow(ctx, `
		SELECT count(*) FROM bm_dev.tournament_team_players ttp
		JOIN bm_dev.players p ON p.id = ttp.player_id
		WHERE ttp.player_id IS NOT NULL`).Scan(&count)
	if err != nil {
		t.Fatalf("count: %v", err)
	}
	if count != 36 {
		t.Fatalf("registered players = %d, want 36", count)
	}
	_ = strings.TrimSpace // keep import
}
