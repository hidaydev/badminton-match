package domain

import (
	"strings"
	"testing"
)

// validTestSnapshot — snapshot yang lolos semua invariant (dipakai sebagai
// baseline; setiap test memecah satu aturan saja).
func validTestSnapshot() *CloudSnapshot {
	return &CloudSnapshot{
		Session: SessionConfig{
			Title:        "Test",
			Date:         "2026-08-12",
			Courts:       1,
			SessionStart: "09:00",
			SlotMinutes:  20,
			CourtTimes:   []CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount:  4,
			CourtNames:   []string{"C1"},
		},
		Players: []Player{
			{ID: "p1", Name: "One", Gender: "M", Tier: 1},
			{ID: "p2", Name: "Two", Gender: "F", Tier: 2},
			{ID: "p3", Name: "Three", Gender: "M", Tier: 3},
			{ID: "p4", Name: "Four", Gender: "M", Tier: 4},
		},
		FixMatches:  []FixMatch{},
		Schedule:    []ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"p1", "p2"}, TeamB: [2]string{"p3", "p4"}}},
		PlayedGames: []string{},
		GameScores:  map[string]GameScore{},
	}
}

func TestValidateSnapshotValid(t *testing.T) {
	if err := ValidateSnapshot(validTestSnapshot()); err != nil {
		t.Fatalf("valid snapshot rejected: %v", err)
	}
}

func TestValidateSnapshotWithScoreAndAbsent(t *testing.T) {
	snap := validTestSnapshot()
	snap.AbsentPlayers = []string{"p4"}
	snap.PlayedGames = []string{"0-0"}
	snap.GameScores = map[string]GameScore{"0-0": {A: 21, B: 15}}
	if err := ValidateSnapshot(snap); err != nil {
		t.Fatalf("valid scored snapshot rejected: %v", err)
	}
}

func TestValidateSnapshotRejects(t *testing.T) {
	tests := []struct {
		name string
		mut  func(*CloudSnapshot) *CloudSnapshot
		want string // substring pesan error
	}{
		{"nil snapshot", func(s *CloudSnapshot) *CloudSnapshot { return nil }, "must not be null"},
		{"blank date", func(s *CloudSnapshot) *CloudSnapshot { s.Session.Date = ""; return s }, "date must not be blank"},
		{"invalid date", func(s *CloudSnapshot) *CloudSnapshot { s.Session.Date = "12/08/2026"; return s }, "valid date"},
		{"invalid sessionStart", func(s *CloudSnapshot) *CloudSnapshot { s.Session.SessionStart = "25:99"; return s }, "valid time"},
		{"non-positive slotMinutes", func(s *CloudSnapshot) *CloudSnapshot { s.Session.SlotMinutes = -5; return s }, "slotMinutes must be positive"},
		{"player blank id", func(s *CloudSnapshot) *CloudSnapshot { s.Players[0].ID = "  "; return s }, "non-blank id/name"},
		{"player blank name", func(s *CloudSnapshot) *CloudSnapshot { s.Players[0].Name = ""; return s }, "non-blank id/name"},
		{"player bad gender", func(s *CloudSnapshot) *CloudSnapshot { s.Players[0].Gender = "X"; return s }, "non-blank id/name"},
		{"player tier out of range", func(s *CloudSnapshot) *CloudSnapshot { s.Players[0].Tier = 9; return s }, "non-blank id/name"},
		{"duplicate player id", func(s *CloudSnapshot) *CloudSnapshot { s.Players[1].ID = "p1"; return s }, "ids must be unique"},
		{"playerCount mismatch", func(s *CloudSnapshot) *CloudSnapshot { s.Session.PlayerCount = 3; return s }, "playerCount must match"},
		{"negative courts", func(s *CloudSnapshot) *CloudSnapshot { s.Session.Courts = -1; return s }, "courts must be non-negative"},
		{"courtTime blank start", func(s *CloudSnapshot) *CloudSnapshot { s.Session.CourtTimes[0].Start = ""; return s }, "ascending start/end"},
		{"courtTime end before start", func(s *CloudSnapshot) *CloudSnapshot { s.Session.CourtTimes[0].End = "08:00"; return s }, "ascending start/end"},
		{"schedule negative slot", func(s *CloudSnapshot) *CloudSnapshot { s.Schedule[0].Slot = -1; return s }, "non-negative slot/court"},
		{"schedule duplicate game", func(s *CloudSnapshot) *CloudSnapshot {
			s.Schedule = append(s.Schedule, ScheduleSlot{Slot: 0, Court: 0, TeamA: [2]string{"p3", "p4"}, TeamB: [2]string{"p1", "p2"}})
			return s
		}, "must not repeat slot/court"},
		{"schedule unknown ref", func(s *CloudSnapshot) *CloudSnapshot { s.Schedule[0].TeamA[0] = "ghost"; return s }, "known non-blank player ids"},
		{"schedule blank ref", func(s *CloudSnapshot) *CloudSnapshot { s.Schedule[0].TeamA[0] = "  "; return s }, "known non-blank player ids"},
		{"same player twice in game", func(s *CloudSnapshot) *CloudSnapshot { s.Schedule[0].TeamB[0] = "p1"; return s }, "not repeat a player"},
		{"valid fixMatch refs accepted", func(s *CloudSnapshot) *CloudSnapshot {
			s.FixMatches = []FixMatch{{ID: "f1", Slots: [4]*string{ptr("p1"), ptr("p2"), nil, nil}}}
			// [4]*string tidak bisa >4 slot — invariant max-4 terjamin struktural.
			return s
		}, "never"},
		{"fixMatch slot kosong (\"\") adalah open slot — lolos", func(s *CloudSnapshot) *CloudSnapshot {
			empty := ""
			s.FixMatches = []FixMatch{{ID: "f1", Slots: [4]*string{ptr("p1"), &empty, &empty, nil}}}
			return s
		}, "never"},
		{"fixMatch unknown ref", func(s *CloudSnapshot) *CloudSnapshot {
			s.FixMatches = []FixMatch{{ID: "f1", Slots: [4]*string{ptr("p1"), ptr("ghost")}}}
			return s
		}, "must only reference known player ids"},
		{"fixMatch duplicate id", func(s *CloudSnapshot) *CloudSnapshot {
			s.FixMatches = []FixMatch{{ID: "f1", Slots: [4]*string{ptr("p1")}}, {ID: "f1", Slots: [4]*string{ptr("p2")}}}
			return s
		}, "ids must be unique"},
		{"absent unknown ref", func(s *CloudSnapshot) *CloudSnapshot { s.AbsentPlayers = []string{"ghost"}; return s }, "known non-blank player ids"},
		{"absent blank ref", func(s *CloudSnapshot) *CloudSnapshot { s.AbsentPlayers = []string{"  "}; return s }, "known non-blank player ids"},
		{"absent duplicate", func(s *CloudSnapshot) *CloudSnapshot { s.AbsentPlayers = []string{"p4", "p4"}; return s }, "must not contain duplicates"},
		{"playedGames unknown game", func(s *CloudSnapshot) *CloudSnapshot { s.PlayedGames = []string{"9-9"}; return s }, "only reference scheduled games"},
		{"playedGames duplicate", func(s *CloudSnapshot) *CloudSnapshot { s.PlayedGames = []string{"0-0", "0-0"}; return s }, "must not contain duplicates"},
		{"gameScore for unplayed game", func(s *CloudSnapshot) *CloudSnapshot { s.GameScores["0-0"] = GameScore{A: 21, B: 15}; return s }, "must only exist for games listed in playedGames"},
		{"gameScore unknown key", func(s *CloudSnapshot) *CloudSnapshot {
			s.PlayedGames = []string{"0-0"}
			s.GameScores["9-9"] = GameScore{A: 21, B: 15}
			return s
		}, "must reference scheduled games"},
		{"gameScore tied", func(s *CloudSnapshot) *CloudSnapshot {
			s.PlayedGames = []string{"0-0"}
			s.GameScores["0-0"] = GameScore{A: 21, B: 21}
			return s
		}, "valid non-tied scores"},
		{"gameScore out of range", func(s *CloudSnapshot) *CloudSnapshot {
			s.PlayedGames = []string{"0-0"}
			s.GameScores["0-0"] = GameScore{A: 100, B: 15}
			return s
		}, "valid non-tied scores"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			snap := validTestSnapshot()
			snap = tt.mut(snap)
			if tt.want == "never" {
				if err := ValidateSnapshot(snap); err != nil {
					t.Fatalf("expected valid, got error: %v", err)
				}
				return
			}
			err := ValidateSnapshot(snap)
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tt.want)
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("error %q does not contain %q", err.Error(), tt.want)
			}
		})
	}
}

func ptr(s string) *string { return &s }
