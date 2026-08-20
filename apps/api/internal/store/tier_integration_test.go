package store

import (
	"context"
	"fmt"
	"testing"
	"time"

	"majadu-api/internal/domain"
)

// TestIntegrationTierFirstSetSticky — first-set tier induk + registered_at saat
// registrasi pertama; STICKY (tier sesi berikutnya tidak menimpa).
func TestIntegrationTierFirstSetSticky(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	players := []domain.Player{
		{ID: "itfs1", Name: "ITFS One", Gender: "M", Tier: 3},   // C
		{ID: "itfs2", Name: "ITFS Two", Gender: "M", Tier: 1},   // D
		{ID: "itfs3", Name: "ITFS Three", Gender: "M", Tier: 4}, // C+
		{ID: "itfs4", Name: "ITFS Four", Gender: "M", Tier: 2},  // D+
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	id := fmt.Sprintf("it-tier-fs-%d", time.Now().UnixNano())
	date := time.Now().AddDate(0, 0, 2).Format("2006-01-02")

	mkSnap := func(overrideTier *int) *domain.CloudSnapshot {
		pl := []domain.Player{}
		for _, p := range players {
			np := p
			if overrideTier != nil {
				np.Tier = *overrideTier
			}
			pl = append(pl, np)
		}
		return &domain.CloudSnapshot{
			Session: domain.SessionConfig{
				Title: "ITFS", Date: date, Courts: 1,
				SessionStart: "09:00", SlotMinutes: 20,
				CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
				PlayerCount: 4, CourtNames: []string{"C1"},
			},
			Players: pl, FixMatches: []domain.FixMatch{},
			Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"itfs1", "itfs2"}, TeamB: [2]string{"itfs3", "itfs4"}}},
			PlayedGames: []string{"0-0"},
			GameScores:  map[string]domain.GameScore{"0-0": {A: 21, B: 10}},
		}
	}
	t.Cleanup(func() {
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.sessions SET status='draft' WHERE share_code LIKE 'it-tier-fs%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE 'it-tier-fs%'`)
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.players SET tier=NULL, registered_at=NULL
			WHERE canonical_name IN ('ITFS One','ITFS Two','ITFS Three','ITFS Four')`)
	})

	// Save pertama (tier C) → first-set
	if _, err := st.Save(ctx, id, mkSnap(nil)); err != nil {
		t.Fatalf("save 1: %v", err)
	}
	getTier := func(name string) (string, string) {
		var tier, ra *string
		if err := st.pool.QueryRow(ctx, `SELECT tier, registered_at::text FROM `+schema+`.players
			WHERE canonical_name = $1`, name).Scan(&tier, &ra); err != nil {
			t.Fatalf("query %s: %v", name, err)
		}
		tv, rv := "", ""
		if tier != nil {
			tv = *tier
		}
		if ra != nil {
			rv = *ra
		}
		return tv, rv
	}
	tier, ra := getTier("ITFS One")
	if tier != "C" || ra != date {
		t.Fatalf("ITFS One first-set: tier=%q registered=%q, want C/%s", tier, ra, date)
	}
	if tier2, _ := getTier("ITFS Two"); tier2 != "D" {
		t.Fatalf("ITFS Two tier=%q, want D", tier2)
	}

	// Save kedua dengan tier BERBEDA → STICKY (tidak menimpa)
	created, _ := st.Load(ctx, id)
	created.Players[0].Tier = 1 // ITFS One → D
	_, _ = st.Unlock(ctx, id)
	if _, err := st.Save(ctx, id, created); err != nil {
		t.Fatalf("save 2: %v", err)
	}
	if tier2, _ := getTier("ITFS One"); tier2 != "C" {
		t.Fatalf("tier induk harus STICKY: got %q, want C (diubah ke D di sesi kedua)", tier2)
	}
}

// TestIntegrationRatingSeasonGate — match sebelum season_start di-skip.
func TestIntegrationRatingSeasonGate(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	players := []domain.Player{
		{ID: "itsg1", Name: "ITSG One", Gender: "M", Tier: 3},
		{ID: "itsg2", Name: "ITSG Two", Gender: "M", Tier: 3},
		{ID: "itsg3", Name: "ITSG Three", Gender: "M", Tier: 3},
		{ID: "itsg4", Name: "ITSG Four", Gender: "M", Tier: 3},
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	id := fmt.Sprintf("it-season-gate-%d", time.Now().UnixNano())
	date := time.Now().AddDate(0, 0, 2).Format("2006-01-02")
	_, err := st.Save(ctx, id, &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "ITSG", Date: date, Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: 4, CourtNames: []string{"C1"},
		},
		Players: players, FixMatches: []domain.FixMatch{},
		Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"itsg1", "itsg2"}, TeamB: [2]string{"itsg3", "itsg4"}}},
		PlayedGames: []string{"0-0"},
		GameScores:  map[string]domain.GameScore{"0-0": {A: 21, B: 10}},
	})
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	created, _ := st.Load(ctx, id)
	created.Session.Locked = true
	if _, err := st.Save(ctx, id, created); err != nil {
		t.Fatalf("lock: %v", err)
	}
	t.Cleanup(func() {
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.sessions SET status='draft' WHERE share_code LIKE 'it-season-gate%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE 'it-season-gate%'`)
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.rating_config SET value='"2026-05-23"' WHERE key='season_start'`)
	})

	// season_start digeser ke MASA DEPAN → semua match jadi pre-season
	if _, err := st.pool.Exec(ctx, `UPDATE `+schema+`.rating_config SET value='"2099-01-01"' WHERE key='season_start'`); err != nil {
		t.Fatalf("set season_start: %v", err)
	}
	res, err := st.IngestSession(ctx, id)
	if err != nil {
		t.Fatalf("ingest pre-season: %v", err)
	}
	if res.Processed != 0 {
		t.Fatalf("pre-season processed=%d, want 0 (gate)", res.Processed)
	}
	foundPreSeason := false
	for _, sk := range res.Skipped {
		if sk.Reason == "pre-season" {
			foundPreSeason = true
		}
	}
	if !foundPreSeason {
		t.Fatalf("tidak ada skipped reason pre-season: %+v", res.Skipped)
	}

	// season_start normal → match ter-rating
	if _, err := st.pool.Exec(ctx, `UPDATE `+schema+`.rating_config SET value='"2026-05-23"' WHERE key='season_start'`); err != nil {
		t.Fatalf("restore season_start: %v", err)
	}
	res2, err := st.IngestSession(ctx, id)
	if err != nil {
		t.Fatalf("ingest normal: %v", err)
	}
	if res2.Processed != 1 {
		t.Fatalf("processed=%d, want 1", res2.Processed)
	}
}
