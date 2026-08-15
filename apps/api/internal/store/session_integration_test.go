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

	pool, err := db.NewPool(context.Background(), url, schema, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatalf("db connect: %v", err)
	}
	defer pool.Close()
	st := NewSessionStore(pool, schema)
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

// TestIntegrationSessionWritePathSemantics — verifikasi invariant write-path Go
// (port publish_session): lock enforcement, version concurrency, unlock, dan
// delete-locked. Hanya jalan dengan MAJADU_TEST_DATABASE_URL (lihat komentar
// TestIntegrationSessionRoundTrip).
func TestIntegrationSessionWritePathSemantics(t *testing.T) {
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
	defer pool.Close()
	st := NewSessionStore(pool, schema)
	ctx := context.Background()

	players := []domain.Player{
		{ID: "itw1", Name: "ITW One", Gender: "M", Tier: 1},
		{ID: "itw2", Name: "ITW Two", Gender: "M", Tier: 2},
		{ID: "itw3", Name: "ITW Three", Gender: "M", Tier: 3},
		{ID: "itw4", Name: "ITW Four", Gender: "M", Tier: 4},
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}

	id := "it-write-" + fmt.Sprintf("%d", time.Now().UnixNano())
	newSnap := func() *domain.CloudSnapshot {
		return &domain.CloudSnapshot{
			Session: domain.SessionConfig{
				Title: "ITW", Date: "2026-08-12", Courts: 1,
				SessionStart: "09:00", SlotMinutes: 20,
				CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
				PlayerCount: len(players),
				CourtNames:  []string{"C1"},
			},
			Players:     players,
			FixMatches:  []domain.FixMatch{},
			Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"itw1", "itw2"}, TeamB: [2]string{"itw3", "itw4"}}},
			PlayedGames: []string{},
			GameScores:  map[string]domain.GameScore{},
		}
	}

	// Create
	created, err := st.Save(ctx, id, newSnap())
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if created.Version == nil || *created.Version != 1 {
		t.Fatalf("expected version 1, got %v", created.Version)
	}

	// Version mismatch → tolak
	stale := newSnap()
	stale.Version = ptrInt(99)
	if _, err := st.Save(ctx, id, stale); !errors.Is(err, ErrVersionMismatch) {
		t.Fatalf("expected ErrVersionMismatch, got %v", err)
	}

	// Lock (version 1 → locked, version 2)
	locked := newSnap()
	locked.Version = ptrInt(1)
	locked.Session.Locked = true
	lockedSnap, err := st.Save(ctx, id, locked)
	if err != nil {
		t.Fatalf("lock: %v", err)
	}
	if lockedSnap.Version == nil || *lockedSnap.Version != 2 {
		t.Fatalf("expected version 2 after lock, got %v", lockedSnap.Version)
	}

	// Write ke session locked → tolak
	again := newSnap()
	again.Version = ptrInt(2)
	if _, err := st.Save(ctx, id, again); !errors.Is(err, ErrLocked) {
		t.Fatalf("expected ErrLocked, got %v", err)
	}

	// Delete session locked → tolak
	if err := st.Delete(ctx, id); !errors.Is(err, ErrLocked) {
		t.Fatalf("expected ErrLocked on delete, got %v", err)
	}

	// Unlock (status → draft, version 3) — via store.Unlock, tanpa If-Match
	unlockedSnap, err := st.Unlock(ctx, id)
	if err != nil {
		t.Fatalf("unlock: %v", err)
	}
	if unlockedSnap.Version == nil || *unlockedSnap.Version != 3 {
		t.Fatalf("expected version 3 after unlock, got %v", unlockedSnap.Version)
	}
	if unlockedSnap.Session.Locked {
		t.Fatal("expected unlocked snapshot")
	}

	// Unlock kedua kali: no-op (tidak bump version)
	again2, err := st.Unlock(ctx, id)
	if err != nil {
		t.Fatalf("unlock idempotent: %v", err)
	}
	if again2.Version == nil || *again2.Version != 3 {
		t.Fatalf("expected version still 3, got %v", again2.Version)
	}

	// Write ke session draft (unlocked) → diterima, version 4
	final := newSnap()
	final.Version = ptrInt(3)
	if _, err := st.Save(ctx, id, final); err != nil {
		t.Fatalf("save after unlock: %v", err)
	}

	// Delete sekarang berhasil
	if err := st.Delete(ctx, id); err != nil {
		t.Fatalf("delete after unlock: %v", err)
	}
}

func ptrInt(n int) *int { return &n }
