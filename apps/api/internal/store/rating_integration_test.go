package store

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"testing"
	"time"

	"majadu-api/internal/db"
	"majadu-api/internal/domain"
)

// ── Integration test rating ingest (RATING_ENGINE_DESIGN.md §4.3/§4.4a) ──
// Hanya jalan dengan MAJADU_TEST_DATABASE_URL (SSH tunnel ke bm_dev).

func ratingTestEnv(t *testing.T) (*SessionStore, string) {
	t.Helper()
	url := os.Getenv("MAJADU_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("MAJADU_TEST_DATABASE_URL not set — skipping integration test")
	}
	schema := os.Getenv("MAJADU_TEST_DB_SCHEMA")
	if schema == "" {
		schema = "bm_dev"
	}
	pool, err := db.NewPool(context.Background(), url, schema, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatalf("db connect: %v", err)
	}
	t.Cleanup(func() { pool.Close() })
	return NewSessionStore(pool, schema), schema
}

// buat + lock sesi (2 game berskor) — helper.
func ratingCreateLockedSession(t *testing.T, st *SessionStore, ctx context.Context, players []domain.Player, suffix string) string {
	t.Helper()
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	id := fmt.Sprintf("it-rating-%s-%d", suffix, time.Now().UnixNano())
	yesterday := time.Now().AddDate(0, 0, -1).Format("2006-01-02")
	snap := &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "Rating IT " + suffix, Date: yesterday, Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: len(players),
			CourtNames:  []string{"C1"},
		},
		Players:    players,
		FixMatches: []domain.FixMatch{},
		Schedule: []domain.ScheduleSlot{
			{Slot: 0, Court: 0, TeamA: [2]string{players[0].ID, players[1].ID}, TeamB: [2]string{players[2].ID, players[3].ID}},
			{Slot: 1, Court: 0, TeamA: [2]string{players[0].ID, players[2].ID}, TeamB: [2]string{players[1].ID, players[3].ID}},
		},
		PlayedGames: []string{"0-0", "1-0"},
		GameScores: map[string]domain.GameScore{
			"0-0": {A: 21, B: 15},
			"1-0": {A: 18, B: 21},
		},
	}
	created, err := st.Save(ctx, id, snap)
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	// lock
	created.Session.Locked = true
	if _, err := st.Save(ctx, id, created); err != nil {
		t.Fatalf("lock: %v", err)
	}
	return id
}

func ratingPlayers(t *testing.T, st *SessionStore, ctx context.Context) map[string]domain.RatingState {
	t.Helper()
	rows, err := st.pool.Query(ctx,
		`SELECT player_id::text, rating, rd FROM `+st.schema+`.rating_players`)
	if err != nil {
		t.Fatalf("query rating_players: %v", err)
	}
	defer rows.Close()
	out := map[string]domain.RatingState{}
	for rows.Next() {
		var id string
		var r domain.RatingState
		if err := rows.Scan(&id, &r.Rating, &r.RD); err != nil {
			t.Fatalf("scan: %v", err)
		}
		out[id] = r
	}
	return out
}

func TestIntegrationRatingIngestSession(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	players := []domain.Player{
		{ID: "itr1", Name: "ITR One", Gender: "M", Tier: 1},
		{ID: "itr2", Name: "ITR Two", Gender: "M", Tier: 2},
		{ID: "itr3", Name: "ITR Three", Gender: "M", Tier: 3},
		{ID: "itr4", Name: "ITR Four", Gender: "M", Tier: 4},
	}
	id := ratingCreateLockedSession(t, st, ctx, players, "sess")

	// Bersihkan data rating dari run ini
	t.Cleanup(func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE 'it-rating-sess%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE 'it-rating-sess%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players`)
	})

	// Ingest pertama
	res, err := st.IngestSession(ctx, id)
	if err != nil {
		t.Fatalf("ingest: %v", err)
	}
	if res.Processed != 2 {
		t.Fatalf("processed = %d, want 2", res.Processed)
	}
	if res.Players != 4 {
		t.Fatalf("players = %d, want 4", res.Players)
	}

	// rating_events & rating_deltas
	var evCount, dlCount int
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.rating_events`).Scan(&evCount); err != nil {
		t.Fatal(err)
	}
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.rating_deltas`).Scan(&dlCount); err != nil {
		t.Fatal(err)
	}
	if evCount != 2 {
		t.Fatalf("events = %d, want 2", evCount)
	}
	if dlCount != 8 {
		t.Fatalf("deltas = %d, want 8 (4 pemain × 2 game)", dlCount)
	}

	// Re-ingest → no-op
	res2, err := st.IngestSession(ctx, id)
	if err != nil {
		t.Fatalf("re-ingest: %v", err)
	}
	if res2.Processed != 0 {
		t.Fatalf("re-ingest processed = %d, want 0 (no-op)", res2.Processed)
	}

	// Snapshot rating sebelum revert
	before := ratingPlayers(t, st, ctx)
	if len(before) != 4 {
		t.Fatalf("rating_players = %d, want 4", len(before))
	}

	// Revert → full rebuild → rating identik (deterministik)
	rev, err := st.RevertSource(ctx, id, "session")
	if err != nil {
		t.Fatalf("revert: %v", err)
	}
	if rev.Processed != -2 {
		t.Fatalf("revert processed = %d, want -2", rev.Processed)
	}
	res3, err := st.IngestSession(ctx, id)
	if err != nil {
		t.Fatalf("re-ingest setelah revert: %v", err)
	}
	if res3.Processed != 2 {
		t.Fatalf("re-ingest processed = %d, want 2", res3.Processed)
	}
	after := ratingPlayers(t, st, ctx)
	for pid, r := range before {
		a, ok := after[pid]
		if !ok {
			t.Fatalf("player %s hilang setelah rebuild", pid)
		}
		if a.Rating != r.Rating || a.RD != r.RD {
			t.Fatalf("player %s: rebuild tidak identik (%.2f/%.2f vs %.2f/%.2f)",
				pid, a.Rating, a.RD, r.Rating, r.RD)
		}
	}

	// Edit skor → ingest → 409 source_changed
	// (unlock via Unlock, ubah skor game 1, save, re-lock)
	if _, err := st.Unlock(ctx, id); err != nil {
		t.Fatalf("unlock: %v", err)
	}
	loaded2, _ := st.Load(ctx, id)
	gs := loaded2.GameScores["0-0"]
	gs.A = 21
	gs.B = 12
	loaded2.GameScores["0-0"] = gs
	if _, err := st.Save(ctx, id, loaded2); err != nil {
		t.Fatalf("save edit: %v", err)
	}
	loaded3, _ := st.Load(ctx, id)
	loaded3.Session.Locked = true
	if _, err := st.Save(ctx, id, loaded3); err != nil {
		t.Fatalf("re-lock: %v", err)
	}

	_, err = st.IngestSession(ctx, id)
	if !errors.Is(err, ErrSourceChanged) {
		t.Fatalf("setelah edit: want ErrSourceChanged, got %v", err)
	}

	// auto_reconcile=true → ingest berjalan (reconcile)
	old := st.pool
	_ = old
	if _, err := st.pool.Exec(ctx, `UPDATE `+schema+`.rating_config SET value='true' WHERE key='auto_reconcile'`); err != nil {
		t.Fatalf("set auto_reconcile: %v", err)
	}
	t.Cleanup(func() {
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.rating_config SET value='false' WHERE key='auto_reconcile'`)
	})
	res4, err := st.IngestSession(ctx, id)
	if err != nil {
		t.Fatalf("ingest auto_reconcile: %v", err)
	}
	if !res4.Reconcile {
		t.Fatal("want reconcile=true")
	}
}

func TestIntegrationRatingIngestGateLocked(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	players := []domain.Player{
		{ID: "itg1", Name: "ITG One", Gender: "M", Tier: 1},
		{ID: "itg2", Name: "ITG Two", Gender: "M", Tier: 2},
		{ID: "itg3", Name: "ITG Three", Gender: "M", Tier: 3},
		{ID: "itg4", Name: "ITG Four", Gender: "M", Tier: 4},
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	id := fmt.Sprintf("it-rating-gate-%d", time.Now().UnixNano())
	today := time.Now().Format("2006-01-02")
	// DRAFT (tidak di-lock) → ingest ditolak ErrSourceNotFinal
	_, err := st.Save(ctx, id, &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "ITG", Date: today, Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: 4, CourtNames: []string{"C1"},
		},
		Players: players, FixMatches: []domain.FixMatch{},
		Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"itg1", "itg2"}, TeamB: [2]string{"itg3", "itg4"}}},
		PlayedGames: []string{"0-0"},
		GameScores:  map[string]domain.GameScore{"0-0": {A: 21, B: 10}},
	})
	if err != nil {
		t.Fatalf("save draft: %v", err)
	}
	t.Cleanup(func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE 'it-rating-gate%'`)
		_ = st.Delete(ctx, id)
	})

	_, err = st.IngestSession(ctx, id)
	if !errors.Is(err, ErrSourceNotFinal) {
		t.Fatalf("draft harus ditolak (ErrSourceNotFinal), got %v", err)
	}
}
