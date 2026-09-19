package domain

import "testing"

func matchFixture() RawMatch {
	return RawMatch{
		StableGameID: "legacy-0",
		Date:         "2026-08-10",
		Kind:         "session",
		SourceID:     "abc123",
		Title:        "IT",
		GameOrder:    "0-0",
		ScoreA:       21,
		ScoreB:       15,
		Target:       21,
		Phase:        "regular",
		Players: []RawPlayer{
			{Name: "One", Team: "A", Position: 0},
			{Name: "Two", Team: "A", Position: 1},
			{Name: "Three", Team: "B", Position: 0},
			{Name: "Four", Team: "B", Position: 1},
		},
	}
}

func TestRawMatchVoid(t *testing.T) {
	m := matchFixture()
	if m.Void() {
		t.Fatal("match normal tidak boleh void")
	}
	// absent di salah satu pemain → void
	m2 := matchFixture()
	m2.Players[2].Absent = true
	if !m2.Void() {
		t.Fatal("match dengan pemain absent harus void")
	}
}

func TestRawMatchMatchKeyStable(t *testing.T) {
	a := matchFixture()
	b := matchFixture()
	if a.MatchKey() != b.MatchKey() {
		t.Fatal("match identik harus punya key yang sama")
	}
	// skor berbeda → key beda
	c := matchFixture()
	c.ScoreB = 12
	if a.MatchKey() == c.MatchKey() {
		t.Fatal("skor beda harus punya key beda")
	}
	// urutan nama dalam tim tidak mengubah key (sorted)
	d := matchFixture()
	d.Players[0], d.Players[1] = d.Players[1], d.Players[0]
	if a.MatchKey() != d.MatchKey() {
		t.Fatal("urutan pemain dalam tim tidak boleh mengubah key")
	}
	// source_id beda → key beda (C2: dua sesi se-date judul sama)
	e := matchFixture()
	e.SourceID = "xyz999"
	if a.MatchKey() == e.MatchKey() {
		t.Fatal("source_id beda harus punya key beda")
	}
}

func TestSourceFingerprint(t *testing.T) {
	a := []RawMatch{matchFixture()}
	b := []RawMatch{matchFixture()}
	fa, err := SourceFingerprint(a)
	if err != nil {
		t.Fatal(err)
	}
	fb, err := SourceFingerprint(b)
	if err != nil {
		t.Fatal(err)
	}
	if fa != fb {
		t.Fatal("fingerprint identik harus sama")
	}
	// skor berubah → fingerprint beda
	c := []RawMatch{matchFixture()}
	c[0].ScoreB = 12
	fc, _ := SourceFingerprint(c)
	if fa == fc {
		t.Fatal("perubahan skor harus mengubah fingerprint")
	}
	// urutan match list tidak mengubah fingerprint (sorted by game_order)
	d := []RawMatch{matchFixture(), matchFixture()}
	d[0].StableGameID = "legacy-1"
	d[0].GameOrder = "1-0"
	d[0].ScoreA, d[0].ScoreB = 18, 21
	e := []RawMatch{d[1], d[0]} // terbalik
	fd, _ := SourceFingerprint(d)
	fe, _ := SourceFingerprint(e)
	if fd != fe {
		t.Fatal("urutan list tidak boleh mengubah fingerprint")
	}
}

func TestPlayersByTeamExcludesPlaceholder(t *testing.T) {
	m := matchFixture()
	m.Players[0].Placeholder = true
	if got := m.PlayersByTeam("A"); len(got) != 1 {
		t.Fatalf("tim A harus 1 pemain real (placeholder disaring), got %d", len(got))
	}
	if got := m.PlaceholdersByTeam("A"); len(got) != 1 {
		t.Fatalf("placeholder tim A harus 1, got %d", len(got))
	}
}

func TestPlayersByTeamExcludesAbsent(t *testing.T) {
	m := matchFixture()
	m.Players[2].Absent = true
	if got := m.PlayersByTeam("B"); len(got) != 1 {
		t.Fatalf("tim B harus 1 pemain real (absent disaring), got %d", len(got))
	}
}

func TestPlayersByTeamInclAbsent(t *testing.T) {
	m := matchFixture()
	m.Players[0].Placeholder = true
	m.Players[2].Absent = true
	if got := m.PlayersByTeamInclAbsent("B"); len(got) != 2 {
		t.Fatalf("tim B harus 2 pemain (absent TETAP dihitung), got %d", len(got))
	}
	if got := m.PlayersByTeamInclAbsent("A"); len(got) != 1 {
		t.Fatalf("tim A harus 1 pemain (placeholder tetap disaring), got %d", len(got))
	}
}

func TestPlayersByTeamExcludesSkipped(t *testing.T) {
	m := matchFixture()
	m.Players[2].Skipped = true
	if got := m.PlayersByTeam("B"); len(got) != 1 {
		t.Fatalf("tim B harus 1 pemain (skipped disaring dari delta), got %d", len(got))
	}
	if got := m.SkippedPlayersByTeam("B"); len(got) != 1 {
		t.Fatalf("pemain skipped tim B harus 1, got %d", len(got))
	}
	// skipped ≠ absent: sisi B tetap punya pemain real (hadir, hanya digantikan)
	if !m.SideHasRealPlayer("B") {
		t.Fatal("tim B dengan pemain skipped harus tetap dianggap punya pemain real")
	}
}

// TestRawMatchVoidIncludesSkipped — policy absent_policy=skip_game membatalkan
// game yang memuat pemain absent MAUPUN yang di-skip per game.
func TestRawMatchVoidIncludesSkipped(t *testing.T) {
	m := matchFixture()
	m.Players[1].Skipped = true
	if !m.Void() {
		t.Fatal("match dengan pemain skipped harus void")
	}
}

func TestMatchRateable(t *testing.T) {
	markTeam := func(m RawMatch, team string, set func(*RawPlayer)) RawMatch {
		for i := range m.Players {
			if m.Players[i].Team == team {
				set(&m.Players[i])
			}
		}
		return m
	}
	skipTeam := func(m RawMatch, team string) RawMatch {
		return markTeam(m, team, func(p *RawPlayer) { p.Skipped = true })
	}

	tests := []struct {
		name      string
		mutate    func(RawMatch) RawMatch
		eligibleA int
		eligibleB int
		want      bool
	}{
		{"normal (kedua sisi eligible)", func(m RawMatch) RawMatch { return m }, 2, 2, true},
		{"satu sisi habis di-skip (digantikan)", func(m RawMatch) RawMatch { return skipTeam(m, "B") }, 2, 0, true},
		{"kedua sisi habis di-skip", func(m RawMatch) RawMatch { return skipTeam(skipTeam(m, "A"), "B") }, 0, 0, false},
		{"satu sisi semua placeholder", func(m RawMatch) RawMatch {
			return markTeam(m, "B", func(p *RawPlayer) { p.Placeholder = true })
		}, 2, 0, false},
		{"satu sisi absent global", func(m RawMatch) RawMatch {
			return markTeam(m, "B", func(p *RawPlayer) { p.Absent = true })
		}, 2, 0, false},
		{"satu sisi kosong tanpa pemain", func(m RawMatch) RawMatch {
			m.Players = m.Players[:2] // buang seluruh tim B
			return m
		}, 2, 0, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			m := tc.mutate(matchFixture())
			if got := m.MatchRateable(tc.eligibleA, tc.eligibleB); got != tc.want {
				t.Fatalf("MatchRateable(%d,%d) = %v, want %v", tc.eligibleA, tc.eligibleB, got, tc.want)
			}
		})
	}
}

// TestSortMatchesByOrderNumeric — game_order "slot-court" harus diurut numerik,
// bukan leksikografis ("0-10" keliru berada sebelum "0-2"). Audit 2026-09-12.
func TestSortMatchesByOrderNumeric(t *testing.T) {
	orders := []string{"10-0", "0-10", "1-0", "0-2", "0-0"}
	matches := make([]RawMatch, 0, len(orders))
	for _, o := range orders {
		matches = append(matches, RawMatch{GameOrder: o})
	}
	SortMatchesByOrder(matches)
	got := make([]string, len(matches))
	for i, m := range matches {
		got[i] = m.GameOrder
	}
	want := []string{"0-0", "0-2", "0-10", "1-0", "10-0"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("urutan = %v, want %v", got, want)
		}
	}

	// Format non-numerik (match_key turnamen) tetap fallback string.
	ms := []RawMatch{{GameOrder: "m-2"}, {GameOrder: "final"}, {GameOrder: "m-10"}}
	SortMatchesByOrder(ms)
	if ms[0].GameOrder != "final" {
		t.Fatalf("fallback string salah: %v", []string{ms[0].GameOrder, ms[1].GameOrder, ms[2].GameOrder})
	}
}
