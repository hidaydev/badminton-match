package store

import (
	"context"
	"fmt"
	"testing"
	"time"

	"majadu-api/internal/domain"
)

// TestIntegrationSeasonReset — alur CloseAndStartSeason: arsip standings musim
// berjalan → musim baru → Glicko musim baru mulai dari mid kelas.
//
// Regression: dulu langkah "hapus events < season_start" membuang history
// lintas musim, sehingga ranking poin ber-window (12 minggu) mustahil dihitung.
// Sekarang events dipertahankan; musim-scoping dilakukan lewat filter
// season_start di rebuildAll.
//
// NOTE: menutup Season 2026-1 di bm_dev (state dev) — cleanup mengembalikan.
func TestIntegrationSeasonReset(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	// Peta tier numerik → kelas: 1..8 = D, D+, C, C+, B, B+, A, A+
	// (session_write.go firstSetPlayerTier).
	players := []domain.Player{
		{ID: "itse1", Name: "ITSE One", Gender: "M", Tier: 3}, // C → mid 1450
		{ID: "itse2", Name: "ITSE Two", Gender: "M", Tier: 3},
		{ID: "itse3", Name: "ITSE Three", Gender: "M", Tier: 1}, // D → mid 1150
		{ID: "itse4", Name: "ITSE Four", Gender: "M", Tier: 1},
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	id := fmt.Sprintf("it-season-reset-%d", time.Now().UnixNano())
	date := time.Now().AddDate(0, 0, 2).Format("2006-01-02")
	if _, err := st.Save(ctx, id, &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "ITSE", Date: date, Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: 4, CourtNames: []string{"C1"},
		},
		Players: players, FixMatches: []domain.FixMatch{},
		Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"itse1", "itse2"}, TeamB: [2]string{"itse3", "itse4"}}},
		PlayedGames: []string{"0-0"},
		GameScores:  map[string]domain.GameScore{"0-0": {A: 21, B: 10}},
	}); err != nil {
		t.Fatalf("save: %v", err)
	}
	saveLock(t, st, ctx, id)

	// Ingest → ada event + rating
	if res, err := st.IngestSession(ctx, id); err != nil || res.Processed != 1 {
		t.Fatalf("ingest: res=%+v err=%v", res, err)
	}

	// Close & Start New Season — tanggal SETELAH sesi (events sesi jadi pre-season baru)
	newStart := time.Now().AddDate(0, 0, 3).Format("2006-01-02")
	newSeasonID, err := st.CloseAndStartSeason(ctx, newStart)
	if err != nil {
		t.Fatalf("close season: %v", err)
	}

	// Verifikasi: 2 musim (2026-1 tertutup, 2026-2 terbuka)
	seasons, err := st.ListSeasons(ctx)
	if err != nil {
		t.Fatalf("list seasons: %v", err)
	}
	if len(seasons) < 2 {
		t.Fatalf("seasons = %d, want ≥2", len(seasons))
	}
	openCount, closedCount := 0, 0
	for _, s := range seasons {
		if s.Open {
			openCount++
		} else {
			closedCount++
		}
	}
	if openCount != 1 || closedCount < 1 {
		t.Fatalf("open=%d closed=%d, want 1/≥1", openCount, closedCount)
	}

	// Arsip: 2026-1 punya snapshot 4 pemain (yang ter-rating sebelum reset)
	var closedID string
	for _, s := range seasons {
		if !s.Open {
			closedID = s.ID
		}
	}
	standings, err := st.SeasonStandings(ctx, closedID)
	if err != nil {
		t.Fatalf("standings: %v", err)
	}
	if len(standings) == 0 {
		t.Fatal("arsip musim tertutup kosong")
	}
	foundITSE := false
	for _, r := range standings {
		if r.Name == "ITSE One" {
			foundITSE = true
		}
	}
	if !foundITSE {
		t.Fatal("ITSE One tidak ada di arsip")
	}

	// Events sesi TIDAK dihapus — history harus awet untuk ranking poin
	// ber-window (12 minggu) yang membaca events lintas musim.
	var evCount int
	if err := st.pool.QueryRow(ctx,
		`SELECT count(*) FROM `+schema+`.rating_events WHERE source_id = $1`, id).Scan(&evCount); err != nil {
		t.Fatalf("hitung events: %v", err)
	}
	if evCount == 0 {
		t.Fatal("events sesi terhapus setelah tutup musim — history hilang, window poin mustahil dihitung")
	}

	// Pre-season baru → Glicko musim ini mengabaikan events < season_start
	// (dikecualikan rebuildAll). Pemain yang PUNYA riwayat memakai benih
	// (rating terakhir), bukan mid kelas — lihat TestIntegrationSeasonSeed.
	pid := resolveIDByAlias(t, st, "itse one")
	dt, err := st.RatingPlayer(ctx, pid)
	if err != nil || dt == nil {
		t.Fatalf("detail: %v", err)
	}
	if dt.Games != 0 {
		t.Fatalf("ITSE One setelah reset: games=%d, want 0 (event di luar musim dikecualikan)", dt.Games)
	}
	if dt.Rating == 1450 {
		t.Fatal("ITSE One jatuh tepat ke mid kelas C (1450) — pemain ber-riwayat harus memakai benih")
	}
	pid3 := resolveIDByAlias(t, st, "itse three")
	dt3, _ := st.RatingPlayer(ctx, pid3)
	if dt3.Games != 0 {
		t.Fatalf("ITSE Three setelah reset: games=%d, want 0", dt3.Games)
	}
	if dt3.Rating == 1150 {
		t.Fatal("ITSE Three jatuh tepat ke mid kelas D (1150) — pemain ber-riwayat harus memakai benih")
	}

	// Cleanup — restore state global dev
	t.Cleanup(func() {
		// Events & sources sesi test ikut dibersihkan: sejak tutup musim tidak
		// lagi menghapus events, sesi test meninggalkan baris permanen yang
		// menggeser max(event.date) dan memicu ErrOutOfOrder di test lain.
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (
			SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE 'it-season-reset%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE 'it-season-reset%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE 'it-season-reset%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_seasons WHERE id <> (SELECT id FROM `+schema+`.rating_seasons WHERE start_date='2026-05-23' LIMIT 1)`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.season_player_snapshots`)
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.rating_seasons SET end_date=NULL, closed_at=NULL`)
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.rating_config SET value='"2026-05-23"' WHERE key='season_start'`)
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.sessions SET status='draft' WHERE share_code LIKE 'it-season-reset%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE 'it-season-reset%'`)
	})
	_ = newSeasonID
}

// TestIntegrationRebuildAllSeasonScoped — rebuildAll hanya memutar events
// ≥ season_start. Ini yang membuat Glicko "musim-scoped" tanpa harus menghapus
// history: events musim lama tetap tersimpan (untuk window poin 12 minggu)
// tetapi tidak dihitung ke rating Glicko musim berjalan.
//
// Regression: sebelum filter season_start ditambahkan, rebuildAll memutar
// SELURUH events, sehingga rating musim baru menyerap semua history lama.
//
// Skenario: ingest sesi di dalam musim → tutup musim (season_start bergeser ke
// masa depan, events lama DIPERTAHANKAN) → rebuildAll harus mengabaikan sesi
// lama itu. Kalau filter hilang, sesi lama ikut terhitung.
func TestIntegrationRebuildAllSeasonScoped(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	const prefix = "it-rbas"
	players := []domain.Player{
		{ID: "rbas1", Name: "RBAS One", Gender: "M", Tier: 3}, // C → mid 1450
		{ID: "rbas2", Name: "RBAS Two", Gender: "M", Tier: 3},
		{ID: "rbas3", Name: "RBAS Three", Gender: "M", Tier: 1}, // D → mid 1150
		{ID: "rbas4", Name: "RBAS Four", Gender: "M", Tier: 1},
	}
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (
			SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE $1)`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE $1`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE $1`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.sessions SET status='draft' WHERE share_code LIKE $1`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE $1`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (
			SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'RBAS %')`)
		// restore musim global
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_seasons WHERE id <> (SELECT id FROM `+schema+`.rating_seasons WHERE start_date='2026-05-23' LIMIT 1)`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.season_player_snapshots`)
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.rating_seasons SET end_date=NULL, closed_at=NULL`)
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.rating_config SET value='"2026-05-23"' WHERE key='season_start'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}

	// Sesi di dalam musim berjalan — HARUS ter-ingest (menghasilkan 1 event).
	// Tanggal: setelah season_start dan setelah event terakhir (invariant kronologis).
	var inSeason string
	if err := st.pool.QueryRow(ctx, `
		SELECT (GREATEST(
			(SELECT (value #>> '{}')::date FROM `+schema+`.rating_config WHERE key='season_start'),
			COALESCE((SELECT max(date) FROM `+schema+`.rating_events), CURRENT_DATE)
		) + INTERVAL '1 day')::date::text`).Scan(&inSeason); err != nil {
		t.Fatalf("hitung tanggal in-season: %v", err)
	}
	inID := prefix + "-in"
	if _, err := st.Save(ctx, inID, &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "RBAS in", Date: inSeason, Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: 4, CourtNames: []string{"C1"},
		},
		Players: players, FixMatches: []domain.FixMatch{},
		Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"rbas1", "rbas2"}, TeamB: [2]string{"rbas3", "rbas4"}}},
		PlayedGames: []string{"0-0"},
		GameScores:  map[string]domain.GameScore{"0-0": {A: 21, B: 10}},
	}); err != nil {
		t.Fatalf("save in: %v", err)
	}
	saveLock(t, st, ctx, inID)
	if r, err := st.IngestSession(ctx, inID); err != nil {
		t.Fatalf("ingest in: %v", err)
	} else if r.Processed != 1 {
		t.Fatalf("sesi dalam musim tidak ter-ingest: %+v", r)
	}

	// Tutup musim: season_start bergeser ke SETELAH sesi tadi. Events lama
	// dipertahankan (tidak boleh dihapus) — inilah yang diuji.
	newStart, err := time.Parse("2006-01-02", inSeason)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if _, err := st.CloseAndStartSeason(ctx, newStart.AddDate(0, 0, 1).Format("2006-01-02")); err != nil {
		t.Fatalf("close season: %v", err)
	}

	// Event sesi lama MASIH ada (history awet untuk window poin).
	var evCount int
	if err := st.pool.QueryRow(ctx,
		`SELECT count(*) FROM `+schema+`.rating_events WHERE source_id = $1`, inID).Scan(&evCount); err != nil {
		t.Fatalf("hitung events: %v", err)
	}
	if evCount == 0 {
		t.Fatal("event sesi hilang setelah tutup musim — history harus awet")
	}

	// RebuildAll: event lama (< season_start baru) harus DIABAIKAN. Buktinya
	// games kembali 0 walau event sesi lama masih ada di tabel. Nilai rating
	// TIDAK dipatok mid kelas: pemain ber-riwayat memakai benih musim
	// (lihat TestIntegrationSeasonSeed).
	pid := resolveIDByAlias(t, st, "rbas one")
	dt, err := st.RatingPlayer(ctx, pid)
	if err != nil || dt == nil {
		t.Fatalf("detail: %v", err)
	}
	if dt.Games != 0 {
		t.Fatalf("RBAS One games=%d, want 0 — event < season_start ikut terhitung (filter season_start hilang di rebuildAll)", dt.Games)
	}
}
