package domain

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// Golden fixture lintas-bahasa (dipakai juga oleh test TS) — mencegah aturan
// urutan kelas/target/jadwal menyimpang antara frontend dan backend.
// Path relatif dari package ini: apps/api/internal/domain → root → apps/web/...
const teamGoldenPath = "../../../../apps/web/scripts/tests/fixtures/team-tournament.golden.json"

type goldenTeamTournament struct {
	PartaiClasses [][2]string    `json:"partaiClasses"`
	Targets       map[string]int `json:"targets"`
	Draw          []struct {
		TeamA int    `json:"teamA"`
		TeamB int    `json:"teamB"`
		Court string `json:"court"`
	} `json:"draw"`
}

func loadTeamGolden(t *testing.T) goldenTeamTournament {
	t.Helper()
	b, err := os.ReadFile(filepath.FromSlash(teamGoldenPath))
	if err != nil {
		t.Fatalf("baca golden fixture: %v", err)
	}
	var g goldenTeamTournament
	if err := json.Unmarshal(b, &g); err != nil {
		t.Fatalf("parse golden fixture: %v", err)
	}
	return g
}

func TestTeamGoldenClassesAndTargets(t *testing.T) {
	g := loadTeamGolden(t)
	if len(g.PartaiClasses) != len(TeamPartaiClasses) {
		t.Fatalf("jumlah partai classes FE %d != BE %d", len(g.PartaiClasses), len(TeamPartaiClasses))
	}
	for i := range TeamPartaiClasses {
		if TeamPartaiClasses[i] != g.PartaiClasses[i] {
			t.Fatalf("partai %d: BE %v != FE %v — urutan kelas harus identik", i, TeamPartaiClasses[i], g.PartaiClasses[i])
		}
	}
	if got, want := TeamTarget("group"), g.Targets["group"]; got != want {
		t.Fatalf("target grup BE %d != FE %d", got, want)
	}
	if got, want := TeamTarget("final"), g.Targets["final"]; got != want {
		t.Fatalf("target final BE %d != FE %d", got, want)
	}
}

// TestTeamGoldenDrawSatisfiesGroupRules — jadwal FE harus memenuhi aturan grup
// backend (9 match, tiap tim 3×, tanpa ulangan lawan).
func TestTeamGoldenDrawSatisfiesGroupRules(t *testing.T) {
	g := loadTeamGolden(t)
	if len(g.Draw) != 9 {
		t.Fatalf("draw FE harus 9 match, dapat %d", len(g.Draw))
	}
	appear := map[int]int{}
	paired := map[string]bool{}
	for _, m := range g.Draw {
		if m.TeamA == m.TeamB {
			t.Fatalf("tim %d tidak boleh melawan diri sendiri", m.TeamA)
		}
		appear[m.TeamA]++
		appear[m.TeamB]++
		a, b := m.TeamA, m.TeamB
		if a > b {
			a, b = b, a
		}
		key := fmt.Sprintf("%d-%d", a, b)
		if paired[key] {
			t.Fatalf("pairing berulang: %s", key)
		}
		paired[key] = true
	}
	for id := 0; id < 6; id++ {
		if appear[id] != 3 {
			t.Fatalf("tim %d muncul %d kali, harus tepat 3", id, appear[id])
		}
	}
}
