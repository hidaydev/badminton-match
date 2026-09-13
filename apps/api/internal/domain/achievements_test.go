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

func TestAchievementKeys(t *testing.T) {
	if got := SessionCountKey(25); got != "session_count:25" {
		t.Fatalf("SessionCountKey = %q", got)
	}
	if got := TierKey("B+"); got != "tier:B+" {
		t.Fatalf("TierKey = %q", got)
	}
	if got := TournamentKey("abc"); got != "tournament:abc" {
		t.Fatalf("TournamentKey = %q", got)
	}
	if got := SeasonMemberKey("s1"); got != "season_member:s1" {
		t.Fatalf("SeasonMemberKey = %q", got)
	}
}

func TestDescribeAchievement(t *testing.T) {
	cases := []struct {
		kind, key string
		value     *int64
		meta      map[string]string
		title     string
	}{
		{"attendance", FirstSessionKey, nil, nil, "Debut"},
		{"attendance", SessionCountKey(25), nil, map[string]string{"count": "25"}, "Setia"},
		{"attendance", StreakKey(5), nil, map[string]string{"count": "5"}, "Konsisten"},
		{"volume", GamesKey(100), nil, map[string]string{"count": "100"}, "Seratus Game"},
		{"volume", WinRateKey, nil, map[string]string{"pct": "60", "min": "20"}, "Efisien"},
		{"tier", TierKey("B+"), nil, map[string]string{"tier": "B+"}, "Naik ke B+"},
		{"rating", RatingKey(2100), nil, map[string]string{"rating": "2100"}, "Klub 2100"},
		{"tournament", TournamentKey("t1"), nil, map[string]string{"name": "Majadu Open"}, "Majadu Open"},
		{"tournament", ChampionKey("t1"), nil, map[string]string{"name": "Majadu Open"}, "Juara Majadu Open"},
		{"opponent", OpponentsKey(25), nil, map[string]string{"count": "25"}, "Teruji"},
		{"season", SeasonChampionKey("s1"), nil, map[string]string{"season": "Season 2026-1"}, "Juara Season 2026-1"},
		{"rank", EstablishedKey, nil, nil, "Mapan"},
	}
	for _, tc := range cases {
		got, _ := DescribeAchievement(tc.kind, tc.key, tc.value, tc.meta)
		if got != tc.title {
			t.Fatalf("DescribeAchievement(%s, %s) title = %q, want %q", tc.kind, tc.key, got, tc.title)
		}
	}
	// Rekor: meta tanpa lawan tidak boleh menyisakan "vs ".
	v := int64(22)
	_, detail := DescribeAchievement("volume", RecordMargin, &v, map[string]string{"margin": "22"})
	if detail != "22 poin" {
		t.Fatalf("record margin detail = %q, want %q", detail, "22 poin")
	}
}
