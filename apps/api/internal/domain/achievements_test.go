package domain

import "testing"

func TestRankTier(t *testing.T) {
	cases := map[string]int{"D": 0, "D+": 1, "C": 2, "C+": 3, "B": 4, "B+": 5, "A": 6, "A+": 7, "X": -1, "": -1}
	for tier, want := range cases {
		if got := RankTier(tier); got != want {
			t.Fatalf("RankTier(%q) = %d, want %d", tier, got, want)
		}
	}
}

func TestMedalKeys(t *testing.T) {
	if got := MedalKey("games"); got != "medal:games" {
		t.Fatalf("MedalKey = %q", got)
	}
	if got := SeasonMedalKey("s1", "wins"); got != "season_medal:s1:wins" {
		t.Fatalf("SeasonMedalKey = %q", got)
	}
	if got := TierKey("B+"); got != "tier:B+" {
		t.Fatalf("TierKey = %q", got)
	}
}

func TestMedalTier(t *testing.T) {
	def, ok := MedalByID("games")
	if !ok {
		t.Fatal("medal games tidak ada")
	}
	// Thresholds: 10/30/75/150/300
	cases := []struct {
		value int64
		level int
		name  string
	}{
		{0, 0, ""},
		{9, 0, ""},
		{10, 1, "Bronze"},
		{29, 1, "Bronze"},
		{30, 2, "Silver"},
		{75, 3, "Gold"},
		{150, 4, "Platinum"},
		{300, 5, "Onyx"},
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
	if next, ok := NextTarget(def, 1); !ok || next != 30 {
		t.Fatalf("NextTarget(level 1) = %d,%v want 30,true", next, ok)
	}
	if _, ok := NextTarget(def, 5); ok {
		t.Fatal("NextTarget(level 5) harus false (sudah Onyx)")
	}
}

func TestTitleForMedal(t *testing.T) {
	title, unit, season, def, ok := TitleForMedal("medal:top_partner")
	if !ok || title != "Top Partner" || unit != "games" || season != "" || def.ID != "top_partner" {
		t.Fatalf("TitleForMedal(medal) = %q %q %q %q %v", title, unit, season, def.ID, ok)
	}
	title, _, season, def, ok = TitleForMedal("season_medal:abc:wins")
	if !ok || title != "Season Wins" || season != "abc" || def.ID != "wins" {
		t.Fatalf("TitleForMedal(season) = %q %q %q %v", title, season, def.ID, ok)
	}
	if _, _, _, _, ok := TitleForMedal("champion:t1"); ok {
		t.Fatal("collectible tidak boleh dianggap medal")
	}
}

func TestDescribeCollectible(t *testing.T) {
	cases := []struct {
		kind, key string
		meta      map[string]string
		title     string
	}{
		{"tier", TierKey("B+"), map[string]string{"tier": "B+"}, "Reached B+"},
		{"tournament", TournamentKey("t1"), map[string]string{"name": "Majadu Open"}, "Majadu Open"},
		{"tournament", ChampionKey("t1"), map[string]string{"name": "Majadu Open"}, "Champion · Majadu Open"},
		{"season", SeasonChampionKey("s1"), map[string]string{"season": "Season 2026-1"}, "Season Champion · Season 2026-1"},
		{"rank", EstablishedKey, nil, "Established"},
		{"volume", EfficientKey, map[string]string{"pct": "60", "min": "20"}, "Efficient"},
	}
	for _, tc := range cases {
		got, _ := DescribeCollectible(tc.kind, tc.key, tc.meta)
		if got != tc.title {
			t.Fatalf("DescribeCollectible(%s, %s) = %q, want %q", tc.kind, tc.key, got, tc.title)
		}
	}
}
