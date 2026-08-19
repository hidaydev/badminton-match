package store

import (
	"context"
	"fmt"
	"testing"
	"time"

	"majadu-api/internal/domain"
)

// TestIntegrationSeasonReset — alur CloseAndStartSeason: arsip standings musim
// berjalan → musim baru → events lama dihapus → semua reset ke mid kelas.
// NOTE: menutup Season 2026-1 di bm_dev (state dev) — cleanup mengembalikan.
func TestIntegrationSeasonReset(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	players := []domain.Player{
		{ID: "itse1", Name: "ITSE One", Gender: "M", Tier: 3}, // C → mid 1450
		{ID: "itse2", Name: "ITSE Two", Gender: "M", Tier: 3},
		{ID: "itse3", Name: "ITSE Three", Gender: "M", Tier: 4}, // D → mid 1150
		{ID: "itse4", Name: "ITSE Four", Gender: "M", Tier: 4},
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
	created, _ := st.Load(ctx, id)
	created.Session.Locked = true
	if _, err := st.Save(ctx, id, created); err != nil {
		t.Fatalf("lock: %v", err)
	}

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

	// Events sesi dihapus (pre-season baru) → pemain reset ke mid kelas
	pid := resolveIDByAlias(t, st, "itse one")
	dt, err := st.RatingPlayer(ctx, pid)
	if err != nil || dt == nil {
		t.Fatalf("detail: %v", err)
	}
	if dt.Games != 0 || dt.Rating != 1450 {
		t.Fatalf("ITSE One setelah reset: games=%d rating=%.2f, want 0/1450 (mid kelas C)", dt.Games, dt.Rating)
	}
	pid3 := resolveIDByAlias(t, st, "itse three")
	dt3, _ := st.RatingPlayer(ctx, pid3)
	if dt3.Games != 0 || dt3.Rating != 1150 {
		t.Fatalf("ITSE Three setelah reset: games=%d rating=%.2f, want 0/1150 (mid kelas D)", dt3.Games, dt3.Rating)
	}

	// Cleanup — restore state global dev
	t.Cleanup(func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_seasons WHERE id <> (SELECT id FROM `+schema+`.rating_seasons WHERE start_date='2026-05-23' LIMIT 1)`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.season_player_snapshots`)
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.rating_seasons SET end_date=NULL, closed_at=NULL`)
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.rating_config SET value='"2026-05-23"' WHERE key='season_start'`)
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.sessions SET status='draft' WHERE share_code LIKE 'it-season-reset%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE 'it-season-reset%'`)
	})
	_ = newSeasonID
}
