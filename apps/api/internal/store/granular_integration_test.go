package store

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"sync"
	"testing"
	"time"

	"majadu-api/internal/db"
	"majadu-api/internal/domain"
)

// Integration test granular live — row-level OCC vs snapshot session lock.
// Hanya jalan saat MAJADU_TEST_DATABASE_URL di-set:
//
//	ssh -f -N -L 15432:127.0.0.1:5432 user@198.51.100.10
//	MAJADU_TEST_DATABASE_URL="postgres://majadu_app:...@localhost:15432/bm_dev" MAJADU_TEST_DB_SCHEMA=bm_dev go test ./internal/store/ -run TestIntegrationGranular
func newGranularTestStore(t *testing.T) *SessionStore {
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
	t.Cleanup(pool.Close)
	return NewSessionStore(pool, schema)
}

// seedGranularSession — buat sesi 8 pemain 2 court 1 slot → 2 game (0-0, 0-1).
func seedGranularSession(t *testing.T, st *SessionStore, ctx context.Context, tag string) string {
	t.Helper()
	players := []domain.Player{
		{ID: "g1", Name: "G One", Gender: "M", Tier: 1},
		{ID: "g2", Name: "G Two", Gender: "M", Tier: 2},
		{ID: "g3", Name: "G Three", Gender: "M", Tier: 3},
		{ID: "g4", Name: "G Four", Gender: "M", Tier: 4},
		{ID: "g5", Name: "G Five", Gender: "M", Tier: 5},
		{ID: "g6", Name: "G Six", Gender: "M", Tier: 6},
		{ID: "g7", Name: "G Seven", Gender: "M", Tier: 7},
		{ID: "g8", Name: "G Eight", Gender: "M", Tier: 8},
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	id := fmt.Sprintf("gran-%s-%d", tag, time.Now().UnixNano())
	snap := &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "Granular IT", Date: "2026-08-24", Courts: 2,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes: []domain.CourtTime{{Start: "09:00", End: "10:00"}, {Start: "09:00", End: "10:00"}},
			PlayerCount: 8,
			CourtNames:  []string{"C1", "C2"},
		},
		Players: players,
		Schedule: []domain.ScheduleSlot{
			{Slot: 0, Court: 0, TeamA: [2]string{"g1", "g2"}, TeamB: [2]string{"g3", "g4"}},
			{Slot: 0, Court: 1, TeamA: [2]string{"g5", "g6"}, TeamB: [2]string{"g7", "g8"}},
		},
		PlayedGames: []string{},
		GameScores:  map[string]domain.GameScore{},
	}
	if _, err := st.Save(ctx, id, snap); err != nil {
		t.Fatalf("save: %v", err)
	}
	t.Cleanup(func() { _ = st.Delete(ctx, id) })
	return id
}

// TestIntegrationGranularDifferentGamesNoContention — 2 goroutine PATCH score
// game beda secara paralel → keduanya sukses (row-level lock, bukan session).
func TestIntegrationGranularDifferentGamesNoContention(t *testing.T) {
	st := newGranularTestStore(t)
	ctx := context.Background()
	id := seedGranularSession(t, st, ctx, "nocont")

	var wg sync.WaitGroup
	errs := make([]error, 2)
	wg.Add(2)
	go func() {
		defer wg.Done()
		g, err := st.GetGame(ctx, id, "0-0")
		if err != nil {
			errs[0] = err
			return
		}
		_, errs[0] = st.SetGameScore(ctx, id, "0-0", 21, 15, &g.Version, "")
	}()
	go func() {
		defer wg.Done()
		g, err := st.GetGame(ctx, id, "0-1")
		if err != nil {
			errs[1] = err
			return
		}
		_, errs[1] = st.SetGameScore(ctx, id, "0-1", 21, 12, &g.Version, "")
	}()
	wg.Wait()
	for i, err := range errs {
		if err != nil {
			t.Fatalf("goroutine %d: %v (expected both success — no contention)", i, err)
		}
	}
	// Verifikasi kedua game tersimpan + version naik independen
	snap, err := st.Load(ctx, id)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if snap.GameScores["0-0"] != (domain.GameScore{A: 21, B: 15}) || snap.GameScores["0-1"] != (domain.GameScore{A: 21, B: 12}) {
		t.Fatalf("scores wrong: %+v", snap.GameScores)
	}
	g0, _ := st.GetGame(ctx, id, "0-0")
	g1, _ := st.GetGame(ctx, id, "0-1")
	if g0.Version != 2 || g1.Version != 2 {
		t.Fatalf("expected both version 2, got %d/%d", g0.Version, g1.Version)
	}
}

// TestIntegrationGranularSameGameVersionConflict — stale version → ErrVersionMismatch.
func TestIntegrationGranularSameGameVersionConflict(t *testing.T) {
	st := newGranularTestStore(t)
	ctx := context.Background()
	id := seedGranularSession(t, st, ctx, "conf")

	g, err := st.GetGame(ctx, id, "0-0")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	stale := g.Version
	if _, err := st.SetGameScore(ctx, id, "0-0", 21, 15, &stale, ""); err != nil {
		t.Fatalf("first set: %v", err)
	}
	// Replay dengan version lama → harus conflict
	_, err = st.SetGameScore(ctx, id, "0-0", 21, 18, &stale, "")
	if !errors.Is(err, ErrVersionMismatch) {
		t.Fatalf("expected ErrVersionMismatch, got %v", err)
	}
	// Score tidak berubah (lost-update dicegah)
	snap, _ := st.Load(ctx, id)
	if snap.GameScores["0-0"] != (domain.GameScore{A: 21, B: 15}) {
		t.Fatalf("score changed despite conflict: %+v", snap.GameScores)
	}
}

// TestIntegrationGranularIdempotency — key sama → response cached, no double bump.
func TestIntegrationGranularIdempotency(t *testing.T) {
	st := newGranularTestStore(t)
	ctx := context.Background()
	id := seedGranularSession(t, st, ctx, "idem")

	key := "test-key-" + id
	g, _ := st.GetGame(ctx, id, "0-0")
	first, err := st.SetGameScore(ctx, id, "0-0", 21, 15, &g.Version, key)
	if err != nil {
		t.Fatalf("first: %v", err)
	}
	// Replay key yang sama (mis. network retry) → harus return cached, TIDAK bump version lagi
	second, err := st.SetGameScore(ctx, id, "0-0", 21, 15, nil, key)
	if err != nil {
		t.Fatalf("second: %v", err)
	}
	if second.Version == nil || first.Version == nil || *second.Version != *first.Version {
		t.Fatalf("idempotency violated: first v%v, second v%v", *first.Version, *second.Version)
	}
	g2, _ := st.GetGame(ctx, id, "0-0")
	if g2.Version != g.Version+1 {
		t.Fatalf("version bumped twice: %d", g2.Version)
	}
}

// TestIntegrationGranularPlayedToggleClearsScore — unplayed hapus score (mirror FE).
func TestIntegrationGranularPlayedToggleClearsScore(t *testing.T) {
	st := newGranularTestStore(t)
	ctx := context.Background()
	id := seedGranularSession(t, st, ctx, "tog")

	g, _ := st.GetGame(ctx, id, "0-0")
	if _, err := st.SetGamePlayed(ctx, id, "0-0", true, &g.Version, ""); err != nil {
		t.Fatalf("played on: %v", err)
	}
	// Set score (auto played)
	g2, _ := st.GetGame(ctx, id, "0-0")
	if _, err := st.SetGameScore(ctx, id, "0-0", 21, 15, &g2.Version, ""); err != nil {
		t.Fatalf("score: %v", err)
	}
	snap, _ := st.Load(ctx, id)
	if _, ok := snap.GameScores["0-0"]; !ok {
		t.Fatal("score missing after set")
	}
	// Unplayed → score harus hilang (mirror setPlayedInSnapshot)
	g3, _ := st.GetGame(ctx, id, "0-0")
	if _, err := st.SetGamePlayed(ctx, id, "0-0", false, &g3.Version, ""); err != nil {
		t.Fatalf("played off: %v", err)
	}
	snap2, _ := st.Load(ctx, id)
	if _, ok := snap2.GameScores["0-0"]; ok {
		t.Fatal("score should be cleared on unplayed")
	}
	if len(snap2.PlayedGames) != 0 {
		t.Fatalf("playedGames should be empty: %+v", snap2.PlayedGames)
	}
}

// TestIntegrationGranularAbsent — set absent granular, session version bump, Load konsisten.
func TestIntegrationGranularAbsent(t *testing.T) {
	st := newGranularTestStore(t)
	ctx := context.Background()
	id := seedGranularSession(t, st, ctx, "abs")

	snap, _ := st.Load(ctx, id)
	v := *snap.Version
	out, err := st.SetAbsentPlayers(ctx, id, []string{"g3", "g7"}, &v, "")
	if err != nil {
		t.Fatalf("absent: %v", err)
	}
	if out.Version == nil || *out.Version != v+1 {
		t.Fatalf("expected version %d, got %v", v+1, out.Version)
	}
	absent := map[string]bool{}
	for _, ref := range out.AbsentPlayers {
		absent[ref] = true
	}
	if !absent["g3"] || !absent["g7"] {
		t.Fatalf("absentPlayers = %+v", out.AbsentPlayers)
	}
	// Reload konsisten
	loaded, _ := st.Load(ctx, id)
	absent2 := map[string]bool{}
	for _, ref := range loaded.AbsentPlayers {
		absent2[ref] = true
	}
	if !absent2["g3"] || len(loaded.AbsentPlayers) != 2 {
		t.Fatalf("reload absent mismatch: %+v", loaded.AbsentPlayers)
	}
}

// helper: cari pemain di (slot, court, team, position)
func gamePlayer(t *testing.T, snap *domain.CloudSnapshot, slot, court int, team string, pos int) string {
	t.Helper()
	for _, g := range snap.Schedule {
		if g.Slot != slot || g.Court != court {
			continue
		}
		arr := g.TeamA
		if team == "B" {
			arr = g.TeamB
		}
		return arr[pos]
	}
	t.Fatalf("game %d-%d not found", slot, court)
	return ""
}

// TestIntegrationGranularSwapPlayer — tukar 1 pemain antar game.
func TestIntegrationGranularSwapPlayer(t *testing.T) {
	st := newGranularTestStore(t)
	ctx := context.Background()
	id := seedGranularSession(t, st, ctx, "swapp")

	snap, _ := st.Load(ctx, id)
	v := *snap.Version
	beforeA := gamePlayer(t, snap, 0, 0, "A", 0) // g1
	beforeB := gamePlayer(t, snap, 0, 1, "A", 0) // g5
	if beforeA == beforeB {
		t.Fatal("setup: same player")
	}
	out, err := st.SwapMembers(ctx, id, "player",
		SwapTarget{Slot: 0, Court: 0, Team: "A", Position: 0},
		SwapTarget{Slot: 0, Court: 1, Team: "A", Position: 0},
		&v, "")
	if err != nil {
		t.Fatalf("swap player: %v", err)
	}
	if got := gamePlayer(t, out, 0, 0, "A", 0); got != beforeB {
		t.Fatalf("expected %s at 0-0/A/0, got %s", beforeB, got)
	}
	if got := gamePlayer(t, out, 0, 1, "A", 0); got != beforeA {
		t.Fatalf("expected %s at 0-1/A/0, got %s", beforeA, got)
	}
	// Session version naik
	if out.Version == nil || *out.Version != v+1 {
		t.Fatalf("expected version %d, got %v", v+1, out.Version)
	}
}

// TestIntegrationGranularSwapTeam — tukar 1 tim (2 pemain) antar game.
func TestIntegrationGranularSwapTeam(t *testing.T) {
	st := newGranularTestStore(t)
	ctx := context.Background()
	id := seedGranularSession(t, st, ctx, "swapt")

	snap, _ := st.Load(ctx, id)
	v := *snap.Version
	beforeA0 := gamePlayer(t, snap, 0, 0, "A", 0)
	beforeA1 := gamePlayer(t, snap, 0, 0, "A", 1)
	beforeB0 := gamePlayer(t, snap, 0, 1, "A", 0)
	beforeB1 := gamePlayer(t, snap, 0, 1, "A", 1)
	out, err := st.SwapMembers(ctx, id, "team",
		SwapTarget{Slot: 0, Court: 0, Team: "A"},
		SwapTarget{Slot: 0, Court: 1, Team: "A"},
		&v, "")
	if err != nil {
		t.Fatalf("swap team: %v", err)
	}
	if gamePlayer(t, out, 0, 0, "A", 0) != beforeB0 || gamePlayer(t, out, 0, 0, "A", 1) != beforeB1 {
		t.Fatalf("team A of 0-0 not swapped: %s,%s want %s,%s",
			gamePlayer(t, out, 0, 0, "A", 0), gamePlayer(t, out, 0, 0, "A", 1), beforeB0, beforeB1)
	}
	if gamePlayer(t, out, 0, 1, "A", 0) != beforeA0 || gamePlayer(t, out, 0, 1, "A", 1) != beforeA1 {
		t.Fatal("team A of 0-1 not swapped")
	}
}

// TestIntegrationGranularSwapSlot — tukar slot/court antar game (key berubah).
func TestIntegrationGranularSwapSlot(t *testing.T) {
	st := newGranularTestStore(t)
	ctx := context.Background()
	id := seedGranularSession(t, st, ctx, "swaps")

	snap, _ := st.Load(ctx, id)
	v := *snap.Version
	g00 := gamePlayer(t, snap, 0, 0, "A", 0) // g1
	g01 := gamePlayer(t, snap, 0, 1, "A", 0) // g5
	out, err := st.SwapMembers(ctx, id, "slot",
		SwapTarget{Slot: 0, Court: 0},
		SwapTarget{Slot: 0, Court: 1},
		&v, "")
	if err != nil {
		t.Fatalf("swap slot: %v", err)
	}
	// Pemain g1 sekarang di 0-1, g5 di 0-0
	if gamePlayer(t, out, 0, 0, "A", 0) != g01 {
		t.Fatalf("expected %s at new 0-0, got %s", g01, gamePlayer(t, out, 0, 0, "A", 0))
	}
	if gamePlayer(t, out, 0, 1, "A", 0) != g00 {
		t.Fatalf("expected %s at new 0-1, got %s", g00, gamePlayer(t, out, 0, 1, "A", 0))
	}
}

// TestIntegrationGranularSwapSameGameRejected — swap target game sama → ditolak.
func TestIntegrationGranularSwapSameGameRejected(t *testing.T) {
	st := newGranularTestStore(t)
	ctx := context.Background()
	id := seedGranularSession(t, st, ctx, "swapi")

	snap, _ := st.Load(ctx, id)
	v := *snap.Version
	_, err := st.SwapMembers(ctx, id, "player",
		SwapTarget{Slot: 0, Court: 0, Team: "A", Position: 0},
		SwapTarget{Slot: 0, Court: 0, Team: "A", Position: 1},
		&v, "")
	if !errors.Is(err, ErrValidation) {
		t.Fatalf("expected ErrValidation for same-game swap, got %v", err)
	}
}

// TestIntegrationGranularSwapStaleVersion — version lama → ErrVersionMismatch.
func TestIntegrationGranularSwapStaleVersion(t *testing.T) {
	st := newGranularTestStore(t)
	ctx := context.Background()
	id := seedGranularSession(t, st, ctx, "swapsv")

	snap, _ := st.Load(ctx, id)
	v := *snap.Version
	if _, err := st.SwapMembers(ctx, id, "player",
		SwapTarget{Slot: 0, Court: 0, Team: "A", Position: 0},
		SwapTarget{Slot: 0, Court: 1, Team: "A", Position: 0},
		&v, ""); err != nil {
		t.Fatalf("first swap: %v", err)
	}
	// Replay dengan version lama
	_, err := st.SwapMembers(ctx, id, "player",
		SwapTarget{Slot: 0, Court: 0, Team: "A", Position: 0},
		SwapTarget{Slot: 0, Court: 1, Team: "A", Position: 0},
		&v, "")
	if !errors.Is(err, ErrVersionMismatch) {
		t.Fatalf("expected ErrVersionMismatch, got %v", err)
	}
}
