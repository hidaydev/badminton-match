package domain

import (
	"strings"
	"testing"
)

func ti(id, name string, players ...TeamPlayer) TeamInfo {
	return TeamInfo{ID: id, Name: name, Players: players}
}

func tp(name, cls string) TeamPlayer { return TeamPlayer{Name: name, Cls: cls} }

func intPtr(n int) *int { return &n }

// buildTeamSnap — 6 tim valid, 9 group match (tiap tim 3×, tanpa ulangan),
// tanpa final, tanpa skor.
func buildTeamSnap() *TeamTournamentSnapshot {
	classes := []string{"A+", "A", "B+", "B", "C+", "C"}
	teams := make([]TeamInfo, 0, 6)
	for i := 0; i < 6; i++ {
		players := make([]TeamPlayer, 0, 6)
		for j, c := range classes {
			players = append(players, tp(strings.ToUpper(string(rune('a'+i)))+string(rune('1'+j)), c))
		}
		teams = append(teams, ti("t"+string(rune('1'+i)), "Tim "+string(rune('1'+i)), players...))
	}
	// jadwal 9 match: tiap tim 3×, tanpa ulangan
	pairs := [][2]string{{"t1", "t2"}, {"t3", "t4"}, {"t5", "t6"}, {"t1", "t3"}, {"t2", "t5"}, {"t4", "t6"}, {"t1", "t4"}, {"t2", "t6"}, {"t3", "t5"}}
	matches := make([]TeamMatch, 0, len(pairs))
	for i, p := range pairs {
		matches = append(matches, TeamMatch{
			ID:     "g-" + string(rune('1'+i)),
			Phase:  "group",
			TeamA:  p[0],
			TeamB:  p[1],
			Partai: []TeamPartai{{}, {}, {}},
		})
	}
	return &TeamTournamentSnapshot{Format: "team", Name: "Team Cup", Date: "2026-08-20", Teams: teams, Matches: matches}
}

func TestValidateTeamValid(t *testing.T) {
	if err := ValidateTeamTournament(buildTeamSnap()); err != nil {
		t.Fatalf("valid snapshot rejected: %v", err)
	}
}

func TestValidateTeamValidUndrawn(t *testing.T) {
	snap := buildTeamSnap()
	snap.Matches = nil
	if err := ValidateTeamTournament(snap); err != nil {
		t.Fatalf("undrawn snapshot rejected: %v", err)
	}
}

func TestValidateTeamValidWithScoresAndFinal(t *testing.T) {
	snap := buildTeamSnap()
	// skor grup: pemenang tepat 30
	snap.Matches[0].Partai = []TeamPartai{
		{ScoreA: intPtr(30), ScoreB: intPtr(28)},
		{ScoreA: intPtr(29), ScoreB: intPtr(30)},
		{ScoreA: intPtr(30), ScoreB: intPtr(25)},
	}
	// final: top-2 (t1 vs t2), rally 42
	snap.Matches = append(snap.Matches, TeamMatch{
		ID: "final", Phase: "final", TeamA: "t1", TeamB: "t2",
		Partai: []TeamPartai{{ScoreA: intPtr(42), ScoreB: intPtr(40)}, {}, {}},
	})
	if err := ValidateTeamTournament(snap); err != nil {
		t.Fatalf("valid scored snapshot rejected: %v", err)
	}
}

func TestValidateTeamRejects(t *testing.T) {
	tests := []struct {
		name string
		mut  func(*TeamTournamentSnapshot)
		want string
	}{
		{"blank name", func(s *TeamTournamentSnapshot) { s.Name = "  " }, "name must not be blank"},
		{"6 teams wajib", func(s *TeamTournamentSnapshot) { s.Teams = s.Teams[:5] }, "exactly 6 teams"},
		{"team id unik", func(s *TeamTournamentSnapshot) { s.Teams[1].ID = s.Teams[0].ID }, "team ids must be unique"},
		{"6 pemain per tim", func(s *TeamTournamentSnapshot) { s.Teams[0].Players = s.Teams[0].Players[:5] }, "exactly 6 players"},
		{"kelas duplikat", func(s *TeamTournamentSnapshot) { s.Teams[0].Players[1].Cls = s.Teams[0].Players[0].Cls }, "each class exactly once"},
		{"kelas invalid", func(s *TeamTournamentSnapshot) { s.Teams[0].Players[0].Cls = "X" }, "must be one of"},
		{"nama pemain kosong", func(s *TeamTournamentSnapshot) { s.Teams[0].Players[0].Name = "" }, "must not be blank"},
		{"nama pemain duplikat antar tim", func(s *TeamTournamentSnapshot) { s.Teams[1].Players[0].Name = s.Teams[0].Players[0].Name }, "unique across the tournament"},
		{"match id duplikat", func(s *TeamTournamentSnapshot) { s.Matches[1].ID = s.Matches[0].ID }, "match ids must be unique"},
		{"self match", func(s *TeamTournamentSnapshot) { s.Matches[0].TeamB = s.Matches[0].TeamA }, "with itself"},
		{"team tak dikenal", func(s *TeamTournamentSnapshot) { s.Matches[0].TeamA = "tX" }, "unknown team"},
		{"3 partai wajib", func(s *TeamTournamentSnapshot) { s.Matches[0].Partai = s.Matches[0].Partai[:2] }, "exactly 3 partai"},
		{"duplikat pairing grup", func(s *TeamTournamentSnapshot) { s.Matches[1].TeamA, s.Matches[1].TeamB = s.Matches[0].TeamA, s.Matches[0].TeamB }, "must not repeat a pairing"},
		{"tim main tidak 3×", func(s *TeamTournamentSnapshot) { s.Matches[0].TeamB = "t5" }, "exactly 3 group matches"},
		{"skor tie", func(s *TeamTournamentSnapshot) { s.Matches[0].Partai[0] = TeamPartai{ScoreA: intPtr(30), ScoreB: intPtr(30)} }, "must not be equal"},
		{"skor bukan target", func(s *TeamTournamentSnapshot) { s.Matches[0].Partai[0] = TeamPartai{ScoreA: intPtr(31), ScoreB: intPtr(28)} }, "reach the target exactly"},
		{"skor final bukan 42", func(s *TeamTournamentSnapshot) {
			s.Matches = append(s.Matches, TeamMatch{ID: "final", Phase: "final", TeamA: "t1", TeamB: "t2", Partai: []TeamPartai{{ScoreA: intPtr(30), ScoreB: intPtr(20)}, {}, {}}})
		}, "reach the target exactly"},
		{"2 final", func(s *TeamTournamentSnapshot) {
			s.Matches = append(s.Matches,
				TeamMatch{ID: "f1", Phase: "final", TeamA: "t1", TeamB: "t2", Partai: []TeamPartai{{}, {}, {}}},
				TeamMatch{ID: "f2", Phase: "final", TeamA: "t3", TeamB: "t4", Partai: []TeamPartai{{}, {}, {}}},
			)
		}, "at most 1 final"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			snap := buildTeamSnap()
			tt.mut(snap)
			err := ValidateTeamTournament(snap)
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tt.want)
			}
			if !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("error %q does not contain %q", err.Error(), tt.want)
			}
		})
	}
}
