package domain

import (
	"fmt"
	"strings"
)

// Katalog achievement dengan model medal bertingkat (adopsi konsep Ingress):
// satu medal punya tangga 5 tingkat Bronze..Onyx, dan yang disimpan hanya
// statistiknya (`value`). Tingkat dihitung dari katalog saat dibaca, jadi tidak
// perlu baris terpisah per ambang.
//
// Dua bentuk achievement:
//   - medal  → key `medal:<id>` / `season_medal:<seasonID>:<id>`, punya value,
//     tingkat diturunkan; nilai naik (upsert), earned_at tetap.
//   - collectible → key spesifik (turnamen, season, breakthrough, one-off),
//     tidak bertingkat, sekali dapat.
//
// Catatan istilah: "tier" di app ini berarti kelas skill (D..A+). Tingkat medal
// disebut "Bronze..Onyx" dan di UI memakai kata "medal"/"pangkat".

type AchievementKind string

const (
	AchAttendance AchievementKind = "attendance"
	AchVolume     AchievementKind = "volume"
	AchOpponent   AchievementKind = "opponent"
	AchTournament AchievementKind = "tournament"
	AchTier       AchievementKind = "tier"
	AchRating     AchievementKind = "rating"
	AchRank       AchievementKind = "rank"
	AchSocial     AchievementKind = "social"
	AchSeason     AchievementKind = "season"
)

// MedalTiers — nama tingkat dari terendah ke tertinggi (level 1..5).
var MedalTiers = []string{"Bronze", "Silver", "Gold", "Platinum", "Onyx"}

// MedalDef — definisi satu medal bertingkat.
type MedalDef struct {
	ID         string // 'sessions', 'games', ...
	Kind       AchievementKind
	Title      string
	Unit       string // satuan tampilan: 'sesi', 'game', 'menang', ...
	Thresholds [5]int64
}

// CareerMedals — medal seumur hidup.
var CareerMedals = []MedalDef{
	{ID: "sessions", Kind: AchAttendance, Title: "Attendance", Unit: "sessions", Thresholds: [5]int64{1, 10, 25, 50, 100}},
	{ID: "streak", Kind: AchAttendance, Title: "Streak", Unit: "sessions", Thresholds: [5]int64{5, 10, 25, 50, 100}},
	{ID: "games", Kind: AchVolume, Title: "Games", Unit: "games", Thresholds: [5]int64{10, 30, 75, 150, 300}},
	{ID: "wins", Kind: AchVolume, Title: "Wins", Unit: "wins", Thresholds: [5]int64{5, 25, 60, 120, 250}},
	{ID: "partners", Kind: AchSocial, Title: "Partners", Unit: "partners", Thresholds: [5]int64{5, 15, 30, 60, 100}},
	{ID: "opponents", Kind: AchOpponent, Title: "Opponents", Unit: "opponents", Thresholds: [5]int64{10, 25, 50, 100, 200}},
	{ID: "rating", Kind: AchRating, Title: "Peak Rating", Unit: "rating", Thresholds: [5]int64{2000, 2100, 2200, 2300, 2400}},
	{ID: "tournaments", Kind: AchTournament, Title: "Tournaments", Unit: "tournaments", Thresholds: [5]int64{1, 3, 8, 15, 30}},
	{ID: "margin", Kind: AchVolume, Title: "Margin", Unit: "points", Thresholds: [5]int64{5, 10, 15, 20, 25}},
	{ID: "top_partner", Kind: AchSocial, Title: "Top Partner", Unit: "games", Thresholds: [5]int64{5, 10, 20, 30, 50}},
}

// SeasonMedals — medal yang dihitung per season (key memuat season id).
var SeasonMedals = []MedalDef{
	{ID: "sessions", Kind: AchSeason, Title: "Season Attendance", Unit: "sessions", Thresholds: [5]int64{1, 5, 10, 15, 20}},
	{ID: "games", Kind: AchSeason, Title: "Season Games", Unit: "games", Thresholds: [5]int64{5, 15, 30, 50, 70}},
	{ID: "wins", Kind: AchSeason, Title: "Season Wins", Unit: "wins", Thresholds: [5]int64{2, 5, 10, 20, 30}},
	{ID: "streak", Kind: AchSeason, Title: "Season Streak", Unit: "sessions", Thresholds: [5]int64{3, 5, 8, 12, 16}},
}

// StatID — penghubung ke perhitungan di store (stat yang dibaca).
const (
	StatSessions   = "sessions"
	StatStreak     = "streak"
	StatGames      = "games"
	StatWins       = "wins"
	StatPartners   = "partners"
	StatOpponents  = "opponents"
	StatRating     = "rating"
	StatTournament = "tournaments"
	StatMargin     = "margin"
	StatTopPartner = "top_partner"
)

// Collectible key + ambang one-off.
const (
	EfficientKey   = "efficient"
	EfficientPct   = 60
	EfficientMin   = 20
	PerfectKey     = "perfect:30-0"
	EstablishedKey = "established"
	EstablishedRD  = 50
)

// ── Key builders ──────────────────────────────────────────────────────────

func MedalKey(id string) string { return "medal:" + id }

func SeasonMedalKey(seasonID, id string) string {
	return "season_medal:" + seasonID + ":" + id
}

func TierKey(tier string) string       { return "tier:" + tier }
func TournamentKey(id string) string   { return "tournament:" + id }
func ChampionKey(id string) string     { return "champion:" + id }
func PodiumKey(id string) string       { return "podium:" + id }
func SeasonMemberKey(id string) string { return "season_member:" + id }
func SeasonChampionKey(id string) string {
	return "season_champion:" + id
}
func SeasonPodiumKey(id string) string { return "season_podium:" + id }

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

// SeasonMedalByID — cari definisi medal season.
func SeasonMedalByID(id string) (MedalDef, bool) {
	for _, d := range SeasonMedals {
		if d.ID == id {
			return d, true
		}
	}
	return MedalDef{}, false
}

// ── Ambang collectible ────────────────────────────────────────────────────

// TierOrder — urutan 8 band skill (dipakai breakthrough tier).
var TierOrder = []string{"D", "D+", "C", "C+", "B", "B+", "A", "A+"}

// RankTier — indeks 0..7 sebuah skill tier; -1 kalau tidak dikenal.
func RankTier(tier string) int {
	for i, t := range TierOrder {
		if t == tier {
			return i
		}
	}
	return -1
}

// ── Judul collectible ─────────────────────────────────────────────────────

// DescribeCollectible — judul + detail untuk achievement non-medal.
func DescribeCollectible(kind, key string, meta map[string]string) (title, detail string) {
	if meta == nil {
		meta = map[string]string{}
	}
	switch AchievementKind(kind) {
	case AchTier:
		return "Reached " + meta["tier"], "Broke through the sticky tier"
	case AchTournament:
		switch {
		case strings.HasPrefix(key, "tournament_count:"):
			return "Tournament Collector", meta["count"] + " tournaments"
		case strings.HasPrefix(key, "champion:"):
			return "Champion · " + meta["name"], "Won the tournament"
		case strings.HasPrefix(key, "podium:"):
			return "Podium · " + meta["name"], "Runner-up / third place"
		case strings.HasPrefix(key, "tournament:"):
			return meta["name"], "Played in the tournament"
		}
	case AchSeason:
		switch {
		case strings.HasPrefix(key, "season_champion:"):
			return "Season Champion · " + meta["season"], "Finished 1st"
		case strings.HasPrefix(key, "season_podium:"):
			return "Season Podium · " + meta["season"], "Finished in the top 3"
		case strings.HasPrefix(key, "season_member:"):
			return "Member · " + meta["season"], "Played this season"
		}
	case AchRank:
		if key == EstablishedKey {
			return "Established", "RD under 50"
		}
	case AchVolume:
		switch key {
		case EfficientKey:
			return "Efficient", fmt.Sprintf("Win rate %s%% over %s games", meta["pct"], meta["min"])
		case PerfectKey:
			return "Perfect", "Won 30-0"
		}
	}
	return key, ""
}

// TitleForMedal — judul sebuah medal (dipakai read path).
func TitleForMedal(key string) (title, unit, seasonID string, levelDef MedalDef, ok bool) {
	if strings.HasPrefix(key, "medal:") {
		def, found := MedalByID(strings.TrimPrefix(key, "medal:"))
		if !found {
			return "", "", "", MedalDef{}, false
		}
		return def.Title, def.Unit, "", def, true
	}
	if strings.HasPrefix(key, "season_medal:") {
		rest := strings.TrimPrefix(key, "season_medal:")
		parts := strings.SplitN(rest, ":", 2)
		if len(parts) != 2 {
			return "", "", "", MedalDef{}, false
		}
		def, found := SeasonMedalByID(parts[1])
		if !found {
			return "", "", "", MedalDef{}, false
		}
		return def.Title, def.Unit, parts[0], def, true
	}
	return "", "", "", MedalDef{}, false
}
