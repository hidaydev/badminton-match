package domain

import "testing"

func TestMedalKeys(t *testing.T) {
	if got := MedalKey("games"); got != "medal:games" {
		t.Fatalf("MedalKey = %q", got)
	}
	if got := TournamentKey("t1"); got != "tournament:t1" {
		t.Fatalf("TournamentKey = %q", got)
	}
	if got := SeasonMemberKey("s1"); got != "season_member:s1" {
		t.Fatalf("SeasonMemberKey = %q", got)
	}
}

func TestCareerMedalCatalog(t *testing.T) {
	want := []string{"sessions", "games", "wins", "rating", "streak", "partners", "opponents"}
	if len(CareerMedals) != len(want) {
		t.Fatalf("jumlah milestone = %d, want %d", len(CareerMedals), len(want))
	}
	for i, id := range want {
		if CareerMedals[i].ID != id {
			t.Fatalf("milestone[%d] = %q, want %q", i, CareerMedals[i].ID, id)
		}
	}
}

func TestMedalTier(t *testing.T) {
	def, ok := MedalByID("games")
	if !ok {
		t.Fatal("medal games tidak ada")
	}
	// Thresholds: 10/25/50/100/200
	cases := []struct {
		value int64
		level int
		name  string
	}{
		{0, 0, ""},
		{9, 0, ""},
		{10, 1, "Bronze"},
		{24, 1, "Bronze"},
		{25, 2, "Silver"},
		{50, 3, "Gold"},
		{100, 4, "Platinum"},
		{200, 5, "Onyx"},
		{9999, 5, "Onyx"},
	}
	for _, tc := range cases {
		if got := TierForValue(def, tc.value); got != tc.level {
			t.Fatalf("TierForValue(games, %d) = %d, want %d", tc.value, got, tc.level)
		}
		if got := TierName(tc.level); got != tc.name {
			t.Fatalf("TierName(%d) = %q, want %q", tc.level, got, tc.name)
		}
	}
	if next, ok := NextTarget(def, 1); !ok || next != 25 {
		t.Fatalf("NextTarget(level 1) = %d,%v want 25,true", next, ok)
	}
	if _, ok := NextTarget(def, 5); ok {
		t.Fatal("NextTarget(level 5) harus false (sudah Onyx)")
	}
}

func TestTitleForMedal(t *testing.T) {
	title, unit, def, ok := TitleForMedal("medal:streak")
	if !ok || title != "Streak" || unit != "sessions" || def.ID != "streak" {
		t.Fatalf("TitleForMedal(medal) = %q %q %q %v", title, unit, def.ID, ok)
	}
	if _, _, _, ok := TitleForMedal("tournament:t1"); ok {
		t.Fatal("event badge tidak boleh dianggap milestone")
	}
}

func TestDescribeCollectible(t *testing.T) {
	cases := []struct {
		key   string
		meta  map[string]string
		title string
	}{
		{"tournament:t1", map[string]string{"name": "Majadu Open"}, "Majadu Open"},
		{"season_member:s1", map[string]string{"season": "Season 2026-1"}, "Member · Season 2026-1"},
	}
	for _, tc := range cases {
		got, _ := DescribeCollectible(tc.key, tc.meta)
		if got != tc.title {
			t.Fatalf("DescribeCollectible(%s) = %q, want %q", tc.key, got, tc.title)
		}
	}
}
