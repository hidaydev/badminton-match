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
