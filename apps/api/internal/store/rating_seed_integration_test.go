package store

import (
	"context"
	"testing"
	"time"

	"majadu-api/internal/domain"
)

// TestIntegrationSeasonSeed — benih rating disegel saat musim ditutup, dan
// rebuild memakainya alih-alih mid kelas.
//
// Dua regresi yang dijaga test ini:
//
//  1. Benih diambil dari rating saat ini membuat rebuild TIDAK idempotent:
//     tiap rebuild memakai hasil rebuild sebelumnya sebagai input, sehingga
//     rating naik terus (terukur: 1495 → 1525 → 1554 untuk satu sesi).
//     Perbaikannya: benih disegel ke kolom seed_* dan hanya ditulis sekali
//     per musim oleh CloseAndStartSeason.
//
//  2. Jalur reset-to-default (pemain yang tidak punya event di musim berjalan)
//     dulu selalu jatuh ke mid kelas, sehingga pemain lama terlempar kembali
//     ke mid kelas tiap ganti musim walau punya riwayat.
func TestIntegrationSeasonSeed(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	players := []domain.Player{
		{ID: "zzt1", Name: "ZZT One", Gender: "M", Tier: 3}, // C → mid 1450
		{ID: "zzt2", Name: "ZZT Two", Gender: "M", Tier: 3},
		{ID: "zzt3", Name: "ZZT Three", Gender: "M", Tier: 1},
		{ID: "zzt4", Name: "ZZT Four", Gender: "M", Tier: 1},
	}
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE 'zzt%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE 'zzt%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE 'zzt%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.scheduled_games WHERE session_id IN (SELECT id FROM `+schema+`.sessions WHERE share_code LIKE 'zzt%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE 'zzt%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'ZZT %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'zzt %'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'ZZT %'`)
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

	// Tanggal setelah season_start dan setelah event terakhir (invariant kronologis).
	var date string
	if err := st.pool.QueryRow(ctx, `
		SELECT (GREATEST(
			(SELECT (value #>> '{}')::date FROM `+schema+`.rating_config WHERE key='season_start'),
			COALESCE((SELECT max(date) FROM `+schema+`.rating_events), CURRENT_DATE)
		) + INTERVAL '1 day')::date::text`).Scan(&date); err != nil {
		t.Fatalf("hitung tanggal: %v", err)
	}

	id := "zzt-sess"
	if _, err := st.Save(ctx, id, &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "ZZT", Date: date, Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: 4, CourtNames: []string{"C1"},
		},
		Players: players, FixMatches: []domain.FixMatch{},
		Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"zzt1", "zzt2"}, TeamB: [2]string{"zzt3", "zzt4"}}},
		PlayedGames: []string{"0-0"},
		GameScores:  map[string]domain.GameScore{"0-0": {A: 21, B: 10}},
	}); err != nil {
		t.Fatalf("save: %v", err)
	}
	saveLock(t, st, ctx, id)
	if r, err := st.IngestSession(ctx, id); err != nil || r.Processed != 1 {
		t.Fatalf("ingest: %+v %v", r, err)
	}

	pid := resolveIDByAlias(t, st, "zzt one")
	readRating := func() (float64, float64) {
		var rating, rd float64
		if err := st.pool.QueryRow(ctx,
			`SELECT rating, rd FROM `+schema+`.rating_players WHERE player_id = $1::uuid`, pid).Scan(&rating, &rd); err != nil {
			t.Fatalf("baca rating: %v", err)
		}
		return rating, rd
	}
	ratingBefore, rdBefore := readRating()

	// RebuildAll harus idempotent (regresi 1).
	if _, err := st.RebuildAll(ctx); err != nil {
		t.Fatalf("rebuild1: %v", err)
	}
	r1, rd1 := readRating()
	if _, err := st.RebuildAll(ctx); err != nil {
		t.Fatalf("rebuild2: %v", err)
	}
	r2, rd2 := readRating()
	if r1 != r2 || rd1 != rd2 {
		t.Fatalf("RebuildAll tidak idempotent: rebuild1=%.4f/%.4f rebuild2=%.4f/%.4f", r1, rd1, r2, rd2)
	}

	// Jeda 60 hari supaya pertumbuhan RD teruji.
	if _, err := st.pool.Exec(ctx,
		`UPDATE `+schema+`.rating_players SET last_played_at = (CURRENT_DATE - 60) WHERE player_id = $1::uuid`,
		pid); err != nil {
		t.Fatalf("set jeda: %v", err)
	}
	ratingPlayed, _ := readRating()

	// Tutup musim: benih harus disegel dari state saat itu.
	sd, err := time.Parse("2006-01-02", date)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if _, err := st.CloseAndStartSeason(ctx, sd.AddDate(0, 0, 1).Format("2006-01-02")); err != nil {
		t.Fatalf("close season: %v", err)
	}

	var seedRating, seedRD *float64
	if err := st.pool.QueryRow(ctx,
		`SELECT seed_rating, seed_rd FROM `+schema+`.rating_players WHERE player_id = $1::uuid`, pid).
		Scan(&seedRating, &seedRD); err != nil {
		t.Fatalf("baca benih: %v", err)
	}
	if seedRating == nil || seedRD == nil {
		t.Fatalf("benih tidak disegel untuk pemain ber-riwayat (seed_rating=%v seed_rd=%v)", seedRating, seedRD)
	}
	if *seedRating != ratingPlayed {
		t.Errorf("seed_rating=%.4f, want rating terakhir %.4f", *seedRating, ratingPlayed)
	}
	if *seedRD <= rdBefore {
		t.Errorf("seed_rd=%.4f tidak tumbuh dari %.4f (jeda 60 hari)", *seedRD, rdBefore)
	}

	// Setelah tutup musim, event lama dikecualikan dari musim baru → pemain
	// masuk jalur reset-to-default, dan HARUS memakai benih (regresi 2),
	// bukan mid kelas (1450 untuk tier C).
	ratingAfter, rdAfter := readRating()
	if ratingAfter != *seedRating {
		t.Errorf("rating setelah tutup musim=%.4f, want benih %.4f — pemain lama jatuh ke mid kelas", ratingAfter, *seedRating)
	}
	// Kolom rating/rd dibulatkan saat disimpan, jadi bandingkan dengan toleransi
	// kecil (bukan kesetaraan bit) — yang penting nilainya berasal dari benih,
	// bukan dari mid kelas tier.
	if diff := rdAfter - *seedRD; diff > 0.01 || diff < -0.01 {
		t.Errorf("rd setelah tutup musim=%.4f, want benih %.4f", rdAfter, *seedRD)
	}
	if ratingAfter == 1450 {
		t.Error("rating jatuh tepat ke mid kelas tier C — benih diabaikan")
	}

	// Idempotensi juga harus berlaku setelah musim berganti.
	if _, err := st.RebuildAll(ctx); err != nil {
		t.Fatalf("rebuild pasca-musim: %v", err)
	}
	r3, rd3 := readRating()
	if r3 != ratingAfter || rd3 != rdAfter {
		t.Fatalf("rebuild pasca-musim mengubah state: %.4f/%.4f → %.4f/%.4f", ratingAfter, rdAfter, r3, rd3)
	}
	_ = ratingBefore
}
