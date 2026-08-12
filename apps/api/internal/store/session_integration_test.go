package store

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"majadu-api/internal/db"
	"majadu-api/internal/domain"
)

// Integration test — round-trip session terhadap Postgres asli.
// Hanya jalan saat MAJADU_TEST_DATABASE_URL di-set (mis. via SSH tunnel):
//
//	ssh -f -N -L 15432:127.0.0.1:5432 user@198.51.100.10
//	MAJADU_TEST_DATABASE_URL="postgres://majadu_app:...@localhost:15432/bm_dev" MAJADU_TEST_DB_SCHEMA=bm_dev go test ./internal/store/
func TestIntegrationSessionRoundTrip(t *testing.T) {
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
	st := NewSessionStore(pool)
	ctx := context.Background()

	players := []domain.Player{
		{ID: "it1", Name: "IT One", Gender: "M", Tier: 1},
		{ID: "it2", Name: "IT Two", Gender: "M", Tier: 2},
		{ID: "it3", Name: "IT Three", Gender: "M", Tier: 3},
		{ID: "it4", Name: "IT Four", Gender: "M", Tier: 4},
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}

	id := "it-session-" + t.Name() + "-" + fmt.Sprintf("%d", time.Now().UnixNano())
	snap := &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "IT", Date: "2026-08-12", Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: len(players),
			CourtNames:  []string{"C1"},
		},
		Players:     players,
		FixMatches:  []domain.FixMatch{},
		Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"it1", "it2"}, TeamB: [2]string{"it3", "it4"}}},
		PlayedGames: []string{},
		GameScores:  map[string]domain.GameScore{},
	}

	created, err := st.Save(ctx, id, snap)
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	if created.Version == nil || *created.Version != 1 {
		t.Fatalf("expected version 1, got %v", created.Version)
	}

	// Mutasi: set score + reload
	if err := created.SetScore("0-0", 21, 18); err != nil {
		t.Fatalf("set score: %v", err)
	}
	updated, err := st.Save(ctx, id, created)
	if err != nil {
		t.Fatalf("save update: %v", err)
	}
	if updated.Version == nil || *updated.Version != 2 {
		t.Fatalf("expected version 2, got %v", updated.Version)
	}
	if updated.GameScores["0-0"] != (domain.GameScore{A: 21, B: 18}) {
		t.Fatalf("score = %+v", updated.GameScores)
	}

	// Reload dari DB
	loaded, err := st.Load(ctx, id)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if loaded.Session.Title != "IT" || len(loaded.Players) != 4 {
		t.Fatalf("loaded mismatch: %+v", loaded)
	}

	// Bersihkan sesi test
	if err := st.Delete(ctx, id); err != nil {
		t.Fatalf("cleanup delete: %v", err)
	}
}
