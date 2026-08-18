package domain

// TeamTournamentSnapshot — kontrak tournament format TIM (6 tim × 6 pemain,
// 3 partai ganda per team-match, rally 30/42). Mirror dari
// frontend TeamTournamentSnapshot (src/queries/types.ts).
type TeamTournamentSnapshot struct {
	Version *int        `json:"version,omitempty"`
	Format  string      `json:"format"` // "team"
	Name    string      `json:"name"`
	Date    string      `json:"date"`
	Teams   []TeamInfo  `json:"teams"`
	Matches []TeamMatch `json:"matches"`
}

// TeamInfo — satu tim (6 pemain = 6 kelas unik A+/A/B+/B/C+/C).
type TeamInfo struct {
	ID      string       `json:"id"`
	Name    string       `json:"name"`
	Players []TeamPlayer `json:"players"`
}

// TeamPlayer — satu pemain dengan kelas (A+/A/B+/B/C+/C).
type TeamPlayer struct {
	Name string `json:"name"`
	Cls  string `json:"cls"`
}

// TeamMatch — satu team-match: 3 partai dengan urutan tetap
// (index 0 = C+ C · 1 = A+ A · 2 = B+ B).
type TeamMatch struct {
	ID     string       `json:"id"`
	Phase  string       `json:"phase"` // "group" | "final"
	TeamA  string       `json:"teamA"`
	TeamB  string       `json:"teamB"`
	Partai []TeamPartai `json:"partai"`
}

// TeamPartai — skor satu partai. Kedua skor null = belum dimainkan.
type TeamPartai struct {
	ScoreA *int `json:"scoreA"`
	ScoreB *int `json:"scoreB"`
}

// TeamClasses — 6 kelas valid (urutan ini juga urutan partai: index 0..2
// memakai pasangan (C+,C) (A+,A) (B+,B)).
var TeamClasses = []string{"A+", "A", "B+", "B", "C+", "C"}

// TeamPartaiClasses — kelas pair per partai (index 0..2), sesuai spesifikasi:
// partai 1 = C+ C, partai 2 = A+ A, partai 3 = B+ B.
var TeamPartaiClasses = [][2]string{{"C+", "C"}, {"A+", "A"}, {"B+", "B"}}
