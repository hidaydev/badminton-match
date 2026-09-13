package domain

import "strings"

// Katalog medal dengan dua kategori (adopsi konsep medal Ingress):
//
//   - Milestone → medal bertingkat, satu badge per statistik, tangga 5 tingkat
//     Bronze..Onyx. Yang disimpan hanya statistiknya (`value`); tingkat dihitung
//     dari katalog saat dibaca, jadi tidak perlu baris terpisah per ambang.
//     Key: `medal:<id>`.
//   - Event → satu badge per event, tidak bertingkat, sekali dapat. Key spesifik
//     per event (`tournament:<id>`, `season_member:<seasonID>`).
//
// Catatan istilah: "tier" di app ini berarti kelas skill (D..A+). Tingkat medal
// disebut Bronze..Onyx; di UI memakai kata "medal".

type AchievementKind string

const (
	AchAttendance AchievementKind = "attendance"
	AchVolume     AchievementKind = "volume"
	AchOpponent   AchievementKind = "opponent"
	AchTournament AchievementKind = "tournament"
	AchSocial     AchievementKind = "social"
	AchRating     AchievementKind = "rating"
	AchSeason     AchievementKind = "season"
)

// MedalTiers — nama tingkat dari terendah ke tertinggi (level 1..5).
var MedalTiers = []string{"Bronze", "Silver", "Gold", "Platinum", "Onyx"}

// MedalDef — definisi satu medal bertingkat.
type MedalDef struct {
	ID         string // 'sessions', 'games', ...
	Kind       AchievementKind
	Title      string
	Unit       string // satuan tampilan: 'sessions', 'games', ...
	Thresholds [5]int64
}

// CareerMedals — tujuh milestone yang dipertahankan. Ambang sengaja renggang
// supaya badge terasa eksklusif (lihat distribusi pemilik saat kurasi).
var CareerMedals = []MedalDef{
	{ID: "sessions", Kind: AchAttendance, Title: "Attendance", Unit: "sessions", Thresholds: [5]int64{5, 10, 15, 20, 25}},
	{ID: "games", Kind: AchVolume, Title: "Games", Unit: "games", Thresholds: [5]int64{10, 25, 50, 100, 200}},
	{ID: "wins", Kind: AchVolume, Title: "Wins", Unit: "wins", Thresholds: [5]int64{5, 20, 50, 100, 200}},
	{ID: "rating", Kind: AchRating, Title: "Peak Rating", Unit: "rating", Thresholds: [5]int64{2000, 2100, 2200, 2300, 2400}},
	{ID: "streak", Kind: AchAttendance, Title: "Streak", Unit: "sessions", Thresholds: [5]int64{3, 5, 8, 12, 16}},
	{ID: "partners", Kind: AchSocial, Title: "Partners", Unit: "partners", Thresholds: [5]int64{5, 15, 30, 60, 100}},
	{ID: "opponents", Kind: AchOpponent, Title: "Opponents", Unit: "opponents", Thresholds: [5]int64{10, 25, 50, 100, 200}},
}

// ── Key builders ──────────────────────────────────────────────────────────

func MedalKey(id string) string { return "medal:" + id }

func TournamentKey(id string) string   { return "tournament:" + id }
func SeasonMemberKey(id string) string { return "season_member:" + id }

// ── Tier helpers ──────────────────────────────────────────────────────────

// TierForValue — level 1..5 untuk sebuah medal; 0 kalau belum mencapai Bronze.
func TierForValue(def MedalDef, v int64) int {
	level := 0
	for i, th := range def.Thresholds {
		if v >= th {
			level = i + 1
		}
	}
	return level
}

// TierName — "Bronze".."Onyx"; string kosong kalau level 0.
func TierName(level int) string {
	if level < 1 || level > len(MedalTiers) {
		return ""
	}
	return MedalTiers[level-1]
}

// NextTarget — ambang tingkat berikutnya; ok=false kalau sudah Onyx.
func NextTarget(def MedalDef, level int) (int64, bool) {
	if level >= len(def.Thresholds) {
		return 0, false
	}
	return def.Thresholds[level], true
}

// MedalByID — cari definisi medal career.
func MedalByID(id string) (MedalDef, bool) {
	for _, d := range CareerMedals {
		if d.ID == id {
			return d, true
		}
	}
	return MedalDef{}, false
}

// ── Judul event medal ─────────────────────────────────────────────────────

// DescribeCollectible — judul + detail untuk badge event (non-milestone).
func DescribeCollectible(key string, meta map[string]string) (title, detail string) {
	if meta == nil {
		meta = map[string]string{}
	}
	switch {
	case strings.HasPrefix(key, "tournament:"):
		return meta["name"], "Played in the tournament"
	case strings.HasPrefix(key, "season_member:"):
		return "Member · " + meta["season"], "Played this season"
	}
	return key, ""
}

// TitleForMedal — judul sebuah milestone dari achievement_key (dipakai read path).
func TitleForMedal(key string) (title, unit string, def MedalDef, ok bool) {
	if !strings.HasPrefix(key, "medal:") {
		return "", "", MedalDef{}, false
	}
	def, found := MedalByID(strings.TrimPrefix(key, "medal:"))
	if !found {
		return "", "", MedalDef{}, false
	}
	return def.Title, def.Unit, def, true
}
