package domain

// TeamTournamentSnapshot — kontrak tournament format TIM (6 tim × 6 pemain,
// 3 partai ganda per team-match, rally 30/42). Mirror dari
// frontend TeamTournamentSnapshot (apps/web/src/utils/teamTournament.ts).
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
	Courts [3]string    `json:"courts"` // 3 nama court, satu entry per partai (boleh sama; default UI 12/13/14)
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

// TeamTarget — target skor per fase: grup 30, final 42. Satu-satunya sumber
// di backend (dipakai validasi & rating extraction).
func TeamTarget(phase string) int {
	if phase == "final" {
		return 42
	}
	return 30
}

// ClassInPartai — apakah kelas pemain ikut main di partai ke-idx.
func ClassInPartai(partaiIdx int, cls string) bool {
	if partaiIdx < 0 || partaiIdx >= len(TeamPartaiClasses) {
		return false
	}
	for _, c := range TeamPartaiClasses[partaiIdx] {
		if cls == c {
			return true
		}
	}
	return false
}

// TeamNames — 6 nama tim kanonik (fixed). Tiap turnamen wajib memakai keenamnya
// tepat sekali (6 tim, unik). Nama ini juga kunci mapping logo di frontend
// (apps/web/src/utils/teamTournament.ts TEAM_NAMES) — dipin golden fixture.
var TeamNames = []string{
	"RED RAPTORS",
	"WHITE FURY",
	"BLUE WAVES",
	"PURPLE PHANTOMS",
	"GREEN GROVE",
	"PINK SPECTRE",
}

// IsTeamName — true bila name (sudah trim) salah satu nama kanonik.
func IsTeamName(name string) bool {
	for _, n := range TeamNames {
		if name == n {
			return true
		}
	}
	return false
}
