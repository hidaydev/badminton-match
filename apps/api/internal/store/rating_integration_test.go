package store

import (
	"context"
	"encoding/json"
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
	// Tanggal FUTURE — data riil bm_dev sudah berisi events s/d hari ini;
	// seq invariant menolak ingest tanggal lebih lama dari max existing.
	future := time.Now().AddDate(0, 0, 2).Format("2006-01-02")
	snap := &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "Rating IT " + suffix, Date: future, Courts: 1,
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

	// Bersihkan data rating run ini SAJA (scoped — DB bersama data backfill).
	// rating_deltas ikut terhapus via FK cascade dari rating_events.
	t.Cleanup(func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE 'it-rating-sess%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE 'it-rating-sess%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (
			SELECT id FROM `+schema+`.players WHERE canonical_name IN ('ITR One','ITR Two','ITR Three','ITR Four'))`)
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.sessions SET status='draft' WHERE share_code LIKE 'it-rating-sess%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE 'it-rating-sess%'`)
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
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.rating_events WHERE source_id LIKE 'it-rating-sess%'`).Scan(&evCount); err != nil {
		t.Fatal(err)
	}
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.rating_deltas rd
		JOIN `+schema+`.rating_events re ON re.id = rd.event_id WHERE re.source_id LIKE 'it-rating-sess%'`).Scan(&dlCount); err != nil {
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

// TestIntegrationRatingReadPathAndTransitivity — read path (leaderboard,
// player, history, sources) + transitivity revert (§4.4a): pemain yang hanya
// main di source LAIN ikut ter-recompute saat source lain di-revert.
func TestIntegrationRatingReadPathAndTransitivity(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	players := []domain.Player{
		{ID: "itt1", Name: "ITT One", Gender: "M", Tier: 1},
		{ID: "itt2", Name: "ITT Two", Gender: "M", Tier: 2},
		{ID: "itt3", Name: "ITT Three", Gender: "M", Tier: 3},
		{ID: "itt4", Name: "ITT Four", Gender: "M", Tier: 4},
		{ID: "itt5", Name: "ITT Five", Gender: "M", Tier: 2},
		{ID: "itt6", Name: "ITT Six", Gender: "M", Tier: 3},
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	t.Cleanup(func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE 'it-rating-tr%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE 'it-rating-tr%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (
			SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'ITT %')`)
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.sessions SET status='draft' WHERE share_code LIKE 'it-rating-tr%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE 'it-rating-tr%'`)
	})

	// Session A: P1-P4 (tidak berbagi dengan B); Session B: P3-P6 (berbagi P3/P4)
	futureA := time.Now().AddDate(0, 0, 2).Format("2006-01-02")
	futureB := time.Now().AddDate(0, 0, 3).Format("2006-01-02")
	idA := fmt.Sprintf("it-rating-tr-A-%d", time.Now().UnixNano())
	idB := fmt.Sprintf("it-rating-tr-B-%d", time.Now().UnixNano())

	mkSession := func(id, date string, pl []domain.Player, label string) {
		_, err := st.Save(ctx, id, &domain.CloudSnapshot{
			Session: domain.SessionConfig{
				Title: "TR " + label, Date: date, Courts: 1,
				SessionStart: "09:00", SlotMinutes: 20,
				CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
				PlayerCount: len(pl), CourtNames: []string{"C1"},
			},
			Players: pl, FixMatches: []domain.FixMatch{},
			Schedule: []domain.ScheduleSlot{
				{Slot: 0, Court: 0, TeamA: [2]string{pl[0].ID, pl[1].ID}, TeamB: [2]string{pl[2].ID, pl[3].ID}},
				{Slot: 1, Court: 0, TeamA: [2]string{pl[0].ID, pl[2].ID}, TeamB: [2]string{pl[1].ID, pl[3].ID}},
			},
			PlayedGames: []string{"0-0", "1-0"},
			GameScores: map[string]domain.GameScore{
				"0-0": {A: 21, B: 15},
				"1-0": {A: 18, B: 21},
			},
		})
		if err != nil {
			t.Fatalf("save %s: %v", label, err)
		}
		// lock
		created, _ := st.Load(ctx, id)
		created.Session.Locked = true
		if _, err := st.Save(ctx, id, created); err != nil {
			t.Fatalf("lock %s: %v", label, err)
		}
	}
	mkSession(idA, futureA, players[:4], "A")
	mkSession(idB, futureB, players[2:], "B")

	// Ingest B dulu (tanggal lebih baru), lalu A (lebih lama) — urutan
	// kronologis: A (2 hari lalu) < B (kemarin).
	// NOTE: ingest harus urut kronologis (seq invariant). Ingest A dulu, baru B.
	if _, err := st.IngestSession(ctx, idA); err != nil {
		t.Fatalf("ingest A: %v", err)
	}
	if _, err := st.IngestSession(ctx, idB); err != nil {
		t.Fatalf("ingest B: %v", err)
	}

	// Read path: leaderboard
	total, rows, err := st.RatingLeaderboard(ctx, false, 100, 0)
	if err != nil {
		t.Fatalf("leaderboard: %v", err)
	}
	// total global berisi data backfill juga — cukup cek row ITT.
	rowByName := map[string]LeaderboardRow{}
	for _, r := range rows {
		rowByName[r.Name] = r
	}
	itt3, ok := rowByName["ITT Three"]
	if !ok || itt3.Games != 4 {
		t.Fatalf("ITT Three leaderboard salah: %+v (ok=%v)", itt3, ok)
	}
	_ = total

	// Read path: player detail + history
	pid3 := resolveIDByAlias(t, st, "itt three")
	d, err := st.RatingPlayer(ctx, pid3)
	if err != nil {
		t.Fatalf("player detail: %v", err)
	}
	if d == nil || d.Games != 4 || d.Tier == 0 {
		t.Fatalf("player detail salah: %+v", d)
	}
	hist, err := st.RatingPlayerHistory(ctx, pid3, 10)
	if err != nil {
		t.Fatalf("history: %v", err)
	}
	if len(hist) != 4 {
		t.Fatalf("history = %d, want 4", len(hist))
	}

	// Read path: sources
	srcs, err := st.ListRatingSources(ctx)
	if err != nil {
		t.Fatalf("sources: %v", err)
	}
	if len(srcs) < 2 {
		t.Fatalf("sources = %d, want ≥2", len(srcs))
	}

	// Revert A → full rebuild. P1/P2 (hanya di A) → reset default (0 game).
	if _, err := st.RevertSource(ctx, idA, "session"); err != nil {
		t.Fatalf("revert A: %v", err)
	}

	// verifikasi P1/P2 reset ke default
	for _, nm := range []string{"ITT One", "ITT Two"} {
		pid := resolveIDByAlias(t, st, lowerAlias(nm))
		dt, err := st.RatingPlayer(ctx, pid)
		if err != nil || dt == nil {
			t.Fatalf("detail %s: %v", nm, err)
		}
		if dt.Games != 0 || dt.Rating != 1250 {
			t.Fatalf("%s setelah revert A: games=%d rating=%.2f, want 0/1250", nm, dt.Games, dt.Rating)
		}
	}

	// TRANSTIVITY: state hasil revert A (hanya B tersisa) HARUS identik dengan
	// fresh ingest B-only. (Asersi "P5 berubah" tidak cukup — delta cap bisa
	// menghasilkan nilai kebetulan sama.)
	stateAfterRevert := ratingPlayers(t, st, ctx)

	// Hapus state rating source TEST saja (A+B), lalu ingest ulang hanya B —
	// backfill tidak tersentuh. stateAfterRevert harus == fresh B-only.
	_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE 'it-rating-tr%'`)
	_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE 'it-rating-tr%'`)
	_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (
		SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'ITT %')`)
	if _, err := st.IngestSession(ctx, idB); err != nil {
		t.Fatalf("fresh ingest B: %v", err)
	}
	stateFreshB := ratingPlayers(t, st, ctx)

	// (Jumlah row bisa beda: reset-to-default menyimpan row P1/P2 dengan 0
	// games — bandingkan hanya pemain aktif dari fresh B.)
	if len(stateFreshB) != 4 {
		t.Fatalf("fresh B players = %d, want 4", len(stateFreshB))
	}
	for pid, r := range stateFreshB {
		a, ok := stateAfterRevert[pid]
		if !ok {
			t.Fatalf("player %s tidak ada di state revert", pid)
		}
		if a.Rating != r.Rating || a.RD != r.RD {
			t.Fatalf("transitivity gagal: player %s revert=%.2f/%.2f vs freshB=%.2f/%.2f",
				pid, a.Rating, a.RD, r.Rating, r.RD)
		}
	}
}

// TestIntegrationAutoIngestLockedSessions — P0 frontend plan: sesi yang
// menjadi locked otomatis diingest oleh ticker helper; draft dilewati;
// leaderboard membawa player_id; history membawa new_rating.
func TestIntegrationAutoIngestLockedSessions(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	players := []domain.Player{
		{ID: "itai1", Name: "ITAI One", Gender: "M", Tier: 1},
		{ID: "itai2", Name: "ITAI Two", Gender: "M", Tier: 2},
		{ID: "itai3", Name: "ITAI Three", Gender: "M", Tier: 3},
		{ID: "itai4", Name: "ITAI Four", Gender: "M", Tier: 4},
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	id := fmt.Sprintf("it-rating-auto-%d", time.Now().UnixNano())
	yesterday := time.Now().AddDate(0, 0, 2).Format("2006-01-02") // future
	mkSnap := func() *domain.CloudSnapshot {
		return &domain.CloudSnapshot{
			Session: domain.SessionConfig{
				Title: "ITAI", Date: yesterday, Courts: 1,
				SessionStart: "09:00", SlotMinutes: 20,
				CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
				PlayerCount: 4, CourtNames: []string{"C1"},
			},
			Players: players, FixMatches: []domain.FixMatch{},
			Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"itai1", "itai2"}, TeamB: [2]string{"itai3", "itai4"}}},
			PlayedGames: []string{"0-0"},
			GameScores:  map[string]domain.GameScore{"0-0": {A: 21, B: 10}},
		}
	}
	t.Cleanup(func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE 'it-rating-auto%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE 'it-rating-auto%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (
			SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE 'it-rating-auto%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (
			SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'ITAI %')`)
		// session bisa locked → unlock dulu, baru delete
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.sessions SET status='draft' WHERE share_code LIKE 'it-rating-auto%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE 'it-rating-auto%'`)
	})

	// Draft → auto-ingest harusnya tidak menyentuh
	if _, err := st.Save(ctx, id, mkSnap()); err != nil {
		t.Fatalf("save draft: %v", err)
	}
	n, err := st.AutoIngestLockedSessions(ctx)
	if err != nil {
		t.Fatalf("auto-ingest: %v", err)
	}
	if n != 0 {
		t.Fatalf("draft ter-ingest (n=%d), want 0", n)
	}

	// Lock → auto-ingest memproses
	created, _ := st.Load(ctx, id)
	created.Session.Locked = true
	if _, err := st.Save(ctx, id, created); err != nil {
		t.Fatalf("lock: %v", err)
	}
	n, err = st.AutoIngestLockedSessions(ctx)
	if err != nil {
		t.Fatalf("auto-ingest: %v", err)
	}
	if n != 1 {
		t.Fatalf("auto-ingest n=%d, want 1", n)
	}

	// Idempotent: kedua kalinya no-op
	n2, err := st.AutoIngestLockedSessions(ctx)
	if err != nil || n2 != 0 {
		t.Fatalf("auto-ingest kedua n=%d err=%v, want 0", n2, err)
	}

	// Leaderboard membawa player_id
	total, rows, err := st.RatingLeaderboard(ctx, false, 100, 0)
	if err != nil {
		t.Fatalf("leaderboard: %v", err)
	}
	if total < 4 {
		t.Fatalf("leaderboard total = %d, want ≥4", total)
	}
	found := 0
	for _, r := range rows {
		if r.PlayerID == "" {
			t.Fatal("leaderboard row tanpa player_id")
		}
		if r.Name == "ITAI One" {
			found++
		}
	}
	if found != 1 {
		t.Fatalf("ITAI One tidak ditemukan di leaderboard")
	}

	// History membawa new_rating
	pid := resolveIDByAlias(t, st, "itai one")
	hist, err := st.RatingPlayerHistory(ctx, pid, 10)
	if err != nil {
		t.Fatalf("history: %v", err)
	}
	if len(hist) == 0 || hist[0].NewRating <= 0 {
		t.Fatalf("history new_rating kosong: %+v", hist)
	}

	// Stats response membawa playerId
	raw, err := NewPlayerStore(st.pool).Stats(ctx, "ITAI One")
	if err != nil {
		t.Fatalf("stats: %v", err)
	}
	var ss struct {
		PlayerID string `json:"playerId"`
	}
	if err := json.Unmarshal(raw, &ss); err != nil {
		t.Fatalf("unmarshal stats: %v", err)
	}
	if ss.PlayerID == "" {
		t.Fatal("stats response tanpa playerId")
	}
}

func resolveIDByAlias(t *testing.T, st *SessionStore, alias string) string {
	t.Helper()
	var pid string
	if err := st.pool.QueryRow(context.Background(),
		`SELECT player_id::text FROM `+st.schema+`.player_aliases WHERE alias_name = $1`, alias).Scan(&pid); err != nil {
		t.Fatalf("resolve alias %q: %v", alias, err)
	}
	return pid
}

func lowerAlias(s string) string {
	out := make([]byte, 0, len(s))
	for _, c := range s {
		if c >= 'A' && c <= 'Z' {
			c += 32
		}
		out = append(out, byte(c))
	}
	return string(out)
}
