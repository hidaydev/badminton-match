package domain

import (
	"testing"
)

func makeSnap() *CloudSnapshot {
	return &CloudSnapshot{
		Session: SessionConfig{Title: "T", Courts: 1},
		Players: []Player{
			{ID: "p1", Name: "A"},
			{ID: "p2", Name: "B"},
			{ID: "p3", Name: "C"},
			{ID: "p4", Name: "D"},
		},
		Schedule: []ScheduleSlot{
			{Slot: 0, Court: 0, TeamA: [2]string{"p1", "p2"}, TeamB: [2]string{"p3", "p4"}},
			{Slot: 1, Court: 0, TeamA: [2]string{"p1", "p3"}, TeamB: [2]string{"p2", "p4"}},
		},
		PlayedGames: []string{},
		GameScores:  map[string]GameScore{},
	}
}

func TestSetScoreValidatesAndAdds(t *testing.T) {
	s := makeSnap()
	if err := s.SetScore("0-0", 21, 18); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got := s.GameScores["0-0"]; got != (GameScore{A: 21, B: 18}) {
		t.Fatalf("score = %+v", got)
	}
	if len(s.PlayedGames) != 1 || s.PlayedGames[0] != "0-0" {
		t.Fatalf("playedGames = %v", s.PlayedGames)
	}
}

func TestSetScoreRejectsEqual(t *testing.T) {
	s := makeSnap()
	if err := s.SetScore("0-0", 21, 21); err == nil {
		t.Fatal("expected error for equal scores")
	}
}

func TestSetScoreRejectsNegative(t *testing.T) {
	s := makeSnap()
	if err := s.SetScore("0-0", -1, 21); err == nil {
		t.Fatal("expected error for negative score")
	}
}

func TestTogglePlayedRemovesScoreWhenUnplaying(t *testing.T) {
	s := makeSnap()
	_ = s.SetScore("0-0", 21, 18)
	s.TogglePlayed("0-0")
	if len(s.PlayedGames) != 0 {
		t.Fatalf("playedGames = %v", s.PlayedGames)
	}
	if _, ok := s.GameScores["0-0"]; ok {
		t.Fatal("score should be removed on unplay")
	}
}

func TestSwapPlayersSameGame(t *testing.T) {
	s := makeSnap()
	s.SwapPlayers(
		SwapTarget{Slot: 0, Court: 0, PlayerID: "p1", Team: "A", Index: 0},
		SwapTarget{Slot: 0, Court: 0, PlayerID: "p3", Team: "B", Index: 0},
	)
	g := s.Schedule[0]
	if g.TeamA[0] != "p3" || g.TeamB[0] != "p1" {
		t.Fatalf("teamA=%v teamB=%v", g.TeamA, g.TeamB)
	}
}

func TestSwapPlayersCrossGame(t *testing.T) {
	s := makeSnap()
	s.SwapPlayers(
		SwapTarget{Slot: 0, Court: 0, PlayerID: "p1", Team: "A", Index: 0},
		SwapTarget{Slot: 1, Court: 0, PlayerID: "p2", Team: "B", Index: 0},
	)
	if s.Schedule[0].TeamA[0] != "p2" {
		t.Fatalf("game0 teamA = %v", s.Schedule[0].TeamA)
	}
	if s.Schedule[1].TeamB[0] != "p1" {
		t.Fatalf("game1 teamB = %v", s.Schedule[1].TeamB)
	}
	// game lain tidak berubah
	if s.Schedule[0].TeamB[0] != "p3" {
		t.Fatalf("game0 teamB = %v", s.Schedule[0].TeamB)
	}
}

func TestSwapSamePlayerIsNoOp(t *testing.T) {
	s := makeSnap()
	before := append([]ScheduleSlot(nil), s.Schedule...)
	s.SwapPlayers(
		SwapTarget{Slot: 0, Court: 0, PlayerID: "p1", Team: "A", Index: 0},
		SwapTarget{Slot: 1, Court: 0, PlayerID: "p1", Team: "A", Index: 0},
	)
	if s.Schedule[0].TeamA[0] != before[0].TeamA[0] {
		t.Fatal("no-op swap should not change schedule")
	}
}

func TestSwapTeams(t *testing.T) {
	s := makeSnap()
	s.SwapTeams(
		TeamSwapTarget{Slot: 0, Court: 0, Team: "A"},
		TeamSwapTarget{Slot: 1, Court: 0, Team: "A"},
	)
	if s.Schedule[0].TeamA != [2]string{"p1", "p3"} {
		t.Fatalf("game0 teamA = %v", s.Schedule[0].TeamA)
	}
	if s.Schedule[1].TeamA != [2]string{"p1", "p2"} {
		t.Fatalf("game1 teamA = %v", s.Schedule[1].TeamA)
	}
}

func TestSwapSlotsMigratesKeys(t *testing.T) {
	s := makeSnap()
	_ = s.SetScore("0-0", 21, 18)
	_ = s.SetScore("1-0", 21, 10)
	s.SwapSlots(SlotSwapTarget{Slot: 0, Court: 0}, SlotSwapTarget{Slot: 1, Court: 0})

	if s.Schedule[0].Slot != 1 || s.Schedule[1].Slot != 0 {
		t.Fatalf("slots not swapped: %+v %+v", s.Schedule[0], s.Schedule[1])
	}
	// playedGames: "0-0" <-> "1-0"
	if s.PlayedGames[0] != "1-0" || s.PlayedGames[1] != "0-0" {
		t.Fatalf("playedGames = %v", s.PlayedGames)
	}
	// gameScores ikut berpindah
	if _, ok := s.GameScores["1-0"]; !ok {
		t.Fatalf("score should move to new key, got %v", s.GameScores)
	}
	if _, ok := s.GameScores["0-0"]; !ok {
		t.Fatalf("score should move to new key, got %v", s.GameScores)
	}
}

func TestRenamePlayer(t *testing.T) {
	s := makeSnap()
	s.RenamePlayer("p1", "Alpha")
	if s.Players[0].Name != "Alpha" {
		t.Fatalf("players = %+v", s.Players)
	}
}

func TestSetAbsent(t *testing.T) {
	s := makeSnap()
	s.SetAbsent([]string{"p4"})
	if len(s.AbsentPlayers) != 1 || s.AbsentPlayers[0] != "p4" {
		t.Fatalf("absent = %v", s.AbsentPlayers)
	}
}

func TestClearScoreDoesNotAddUnplayedGame(t *testing.T) {
	s := makeSnap()
	// Game yang belum played: ClearScore TIDAK boleh menambahkannya.
	s.ClearScore("0-0")
	if len(s.PlayedGames) != 0 {
		t.Fatalf("ClearScore on unplayed game must not add to playedGames, got %v", s.PlayedGames)
	}
}

func TestClearScoreRemovesPlayedAndScore(t *testing.T) {
	s := makeSnap()
	_ = s.SetScore("0-0", 21, 18)
	s.ClearScore("0-0")
	if len(s.PlayedGames) != 0 {
		t.Fatalf("playedGames = %v", s.PlayedGames)
	}
	if _, ok := s.GameScores["0-0"]; ok {
		t.Fatal("score should be removed")
	}
}

func TestValidateScoreCapsAt99(t *testing.T) {
	if err := ValidateScore(100, 98); err == nil {
		t.Fatal("expected error for score > 99")
	}
	if err := ValidateScore(99, 98); err != nil {
		t.Fatalf("99 should be valid: %v", err)
	}
}

func TestSwapTargetValidate(t *testing.T) {
	cases := []struct {
		name string
		t    SwapTarget
		ok   bool
	}{
		{"valid", SwapTarget{Slot: 0, Court: 0, PlayerID: "a", Team: "A", Index: 0}, true},
		{"bad team", SwapTarget{Slot: 0, Court: 0, PlayerID: "a", Team: "C", Index: 0}, false},
		{"bad index", SwapTarget{Slot: 0, Court: 0, PlayerID: "a", Team: "A", Index: 5}, false},
		{"missing player", SwapTarget{Slot: 0, Court: 0, PlayerID: "", Team: "A", Index: 0}, false},
	}
	for _, c := range cases {
		err := c.t.Validate()
		if (err == nil) != c.ok {
			t.Fatalf("%s: Validate() = %v, want ok=%v", c.name, err, c.ok)
		}
	}
}

func TestTeamSwapTargetValidate(t *testing.T) {
	if err := (TeamSwapTarget{Slot: 0, Court: 0, Team: "Z"}).Validate(); err == nil {
		t.Fatal("team Z should be rejected")
	}
	if err := (TeamSwapTarget{Slot: 0, Court: 0, Team: "B"}).Validate(); err != nil {
		t.Fatalf("team B should be valid: %v", err)
	}
}
