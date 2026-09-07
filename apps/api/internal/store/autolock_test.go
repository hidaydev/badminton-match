package store

import (
	"testing"

	"majadu-api/internal/domain"
)

// ── Unit test auto-lock "all games decided" (pure, tanpa DB) ───────────────

func TestCountDecidedGames(t *testing.T) {
	tests := []struct {
		name      string
		schedule  []domain.ScheduleSlot
		scores    map[string]domain.GameScore
		skipped   map[string][]string
		wantCount int
	}{
		{
			name:      "semua ber-skor",
			schedule:  []domain.ScheduleSlot{{Slot: 0, Court: 0}, {Slot: 0, Court: 1}},
			scores:    map[string]domain.GameScore{"0-0": {A: 21, B: 19}, "0-1": {A: 21, B: 15}},
			wantCount: 2,
		},
		{
			name:      "satu kosong belum di-skip → belum beres",
			schedule:  []domain.ScheduleSlot{{Slot: 0, Court: 0}, {Slot: 0, Court: 1}},
			scores:    map[string]domain.GameScore{"0-0": {A: 21, B: 19}},
			wantCount: 1,
		},
		{
			name:      "satu game skip semua pemain → beres",
			schedule:  []domain.ScheduleSlot{{Slot: 0, Court: 0}, {Slot: 8, Court: 2, TeamA: [2]string{"p1", "p2"}, TeamB: [2]string{"p3", "p4"}}},
			scores:    map[string]domain.GameScore{"0-0": {A: 21, B: 19}},
			skipped:   map[string][]string{"8-2": {"p1", "p2", "p3", "p4"}},
			wantCount: 2,
		},
		{
			name:      "skip sebagian pemain → belum beres",
			schedule:  []domain.ScheduleSlot{{Slot: 0, Court: 0}, {Slot: 0, Court: 1}},
			scores:    map[string]domain.GameScore{"0-0": {A: 21, B: 19}},
			skipped:   map[string][]string{"0-1": {"p5"}},
			wantCount: 1,
		},
		{
			name: "semua game di-skip penuh → semua beres",
			schedule: []domain.ScheduleSlot{
				{Slot: 0, Court: 0, TeamA: [2]string{"p1", "p2"}, TeamB: [2]string{"p3", "p4"}},
				{Slot: 0, Court: 1, TeamA: [2]string{"p5", "p6"}, TeamB: [2]string{"p7", "p8"}},
			},
			skipped: map[string][]string{
				"0-0": {"p1", "p2", "p3", "p4"},
				"0-1": {"p5", "p6", "p7", "p8"},
			},
			wantCount: 2,
		},
		{
			name:      "schedule kosong → 0",
			schedule:  []domain.ScheduleSlot{},
			wantCount: 0,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			snap := &domain.CloudSnapshot{
				Schedule:       tt.schedule,
				GameScores:     tt.scores,
				SkippedPlayers: tt.skipped,
			}
			if got := countDecidedGames(snap); got != tt.wantCount {
				t.Errorf("countDecidedGames() = %d, want %d", got, tt.wantCount)
			}
		})
	}
}

func TestGameFullySkipped(t *testing.T) {
	tests := []struct {
		name    string
		g       domain.ScheduleSlot
		skipped []string
		want    bool
	}{
		{
			name:    "semua 4 pemain di-skip",
			g:       domain.ScheduleSlot{TeamA: [2]string{"a", "b"}, TeamB: [2]string{"c", "d"}},
			skipped: []string{"a", "b", "c", "d"},
			want:    true,
		},
		{
			name:    "hanya 1 pemain di-skip",
			g:       domain.ScheduleSlot{TeamA: [2]string{"a", "b"}, TeamB: [2]string{"c", "d"}},
			skipped: []string{"a"},
			want:    false,
		},
		{
			name:    "skip pemain yang tidak ada di game",
			g:       domain.ScheduleSlot{TeamA: [2]string{"a", "b"}, TeamB: [2]string{"c", "d"}},
			skipped: []string{"a", "b", "c", "d", "zzz"},
			want:    true,
		},
		{
			name:    "slot kosong tidak dihitung",
			g:       domain.ScheduleSlot{TeamA: [2]string{"a", ""}, TeamB: [2]string{"", ""}},
			skipped: []string{"a"},
			want:    true,
		},
		{
			name:    "tanpa pemain sama sekali tidak beres",
			g:       domain.ScheduleSlot{},
			skipped: []string{"a"},
			want:    false,
		},
		{
			name:    "tanpa skip → tidak beres",
			g:       domain.ScheduleSlot{TeamA: [2]string{"a", "b"}, TeamB: [2]string{"c", "d"}},
			skipped: nil,
			want:    false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := gameFullySkipped(tt.g, tt.skipped); got != tt.want {
				t.Errorf("gameFullySkipped() = %v, want %v", got, tt.want)
			}
		})
	}
}
