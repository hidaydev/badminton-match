package store

import (
	"testing"

	"majadu-api/internal/domain"
)

// Ambang min-sesi menyembunyikan pemain dengan entri (sesi) sedikit, dan
// peringkat dihitung pada himpunan yang tersisa.
func TestBoardRowsMinSessionsFilter(t *testing.T) {
	cfg := domain.DefaultRatingConfig
	cfg.RankMinSessions = 3
	cfg.RankBestN = 10

	entries := []rankPointEntryRow{
		{playerID: "p1", entry: RankPointEntry{SourceID: "s1", Date: "2026-01-05", Points: 500}},
		{playerID: "p2", entry: RankPointEntry{SourceID: "s1", Date: "2026-01-05", Points: 100}},
		{playerID: "p2", entry: RankPointEntry{SourceID: "s2", Date: "2026-01-08", Points: 100}},
		{playerID: "p2", entry: RankPointEntry{SourceID: "s3", Date: "2026-01-12", Points: 100}},
	}
	names := map[string]string{"p1": "One", "p2": "Two"}
	tiers := map[string]string{"p1": "C+", "p2": "A"}

	rows := boardRowsFromEntries(entries, cfg, names, tiers, 0)
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1 (p1 tersaring)", len(rows))
	}
	if rows[0].PlayerID != "p2" || rows[0].Rank != 1 || rows[0].Tier != "A" {
		t.Fatalf("rows[0] = %+v, want p2 rank 1 tier A", rows[0])
	}

	// Ambang 0 → tanpa filter.
	cfg.RankMinSessions = 0
	if got := boardRowsFromEntries(entries, cfg, names, tiers, 0); len(got) != 2 {
		t.Fatalf("rows = %d, want 2 (tanpa ambang)", len(got))
	}
}

// Best rank + run top-3 terpanjang; absen dari papan memutus run.
func TestComputeRankStats(t *testing.T) {
	dates := []string{"d1", "d2", "d3", "d4"}
	byDate := map[string]map[string]int{
		"d1": {"a": 1, "b": 4},
		"d2": {"a": 2, "b": 3},
		"d3": {"a": 5, "b": 1},
		"d4": {"a": 1, "b": 2},
	}
	st := computeRankStats(dates, byDate)

	a := st["a"]
	if a.best != 1 || a.bestDate != "d1" {
		t.Fatalf("a.best = %d@%s, want 1@d1", a.best, a.bestDate)
	}
	if a.streak != 2 || a.streakDate != "d2" {
		t.Fatalf("a.streak = %d@%s, want 2@d2", a.streak, a.streakDate)
	}

	b := st["b"]
	if b.best != 1 || b.bestDate != "d3" {
		t.Fatalf("b.best = %d@%s, want 1@d3", b.best, b.bestDate)
	}
	if b.streak != 3 || b.streakDate != "d4" {
		t.Fatalf("b.streak = %d@%s, want 3@d4", b.streak, b.streakDate)
	}
}
