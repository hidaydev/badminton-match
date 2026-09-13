package domain

import (
	"fmt"
	"strconv"
	"strings"
)

// Katalog achievement (slice A: achievement Kelas A yang bisa di-backfill dari
// data yang masih ada). Definisi judul/ambang tinggal di kode; tabel hanya
// menyimpan fakta unlock supaya ganti copy tidak perlu migration.
//
// Aturan key:
//   - ambang/per-event/per-season → achievement_key unik + ON CONFLICT DO NOTHING
//   - rekor (value bisa naik) → ON CONFLICT DO UPDATE bila value lebih besar
//     (earned_at tetap tanggal pertama)

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

// TierOrder — urutan 8-band dari terendah ke tertinggi (dipakai ordinal tier).
var TierOrder = []string{"D", "D+", "C", "C+", "B", "B+", "A", "A+"}

// RankTier — indeks 0..7 sebuah tier; -1 kalau tidak dikenal.
func RankTier(tier string) int {
	for i, t := range TierOrder {
		if t == tier {
			return i
		}
	}
	return -1
}

// Ambang achievement (diurut naik).
var (
	SessionCountThresholds = []int64{10, 25, 50, 100}
	StreakThresholds       = []int64{5, 10, 25}
	GamesThresholds        = []int64{10, 50, 100, 250}
	WinsThresholds         = []int64{10, 50, 100, 250}
	RatingThresholds       = []int64{2000, 2100, 2200, 2400}
	TournamentThresholds   = []int64{1, 5, 10}
	PartnerThresholds      = []int64{10, 25, 50}
	OpponentThresholds     = []int64{25, 50}
)

const (
	WinRatePct        = 60 // ambang win rate (persen)
	WinRateMinGames   = 20 // minimum game agar win rate dianggap valid
	MarginThreshold   = 20 // selisih poin untuk achievement "Dominan"
	EstablishedRD     = 50 // RD di bawah ini dianggap mapan
	PerfectScoreSelf  = 30 // skor menang sempurna
	PerfectScoreOther = 0
	FirstSessionKey   = "session:first"
	WinRateKey        = "winrate:60:20"
	EstablishedKey    = "established"
	PerfectKey        = "perfect:30-0"
	MarginKey         = "margin:20"
	RecordMargin      = "record:margin"
	RecordTopPartner  = "record:top_partner"
	RecordStreak      = "record:session_streak"
)

// ── Key builders ──────────────────────────────────────────────────────────

func SessionCountKey(n int64) string { return "session_count:" + strconv.FormatInt(n, 10) }
func StreakKey(n int64) string       { return "streak:" + strconv.FormatInt(n, 10) }
func GamesKey(n int64) string        { return "games:" + strconv.FormatInt(n, 10) }
func WinsKey(n int64) string         { return "wins:" + strconv.FormatInt(n, 10) }
func RatingKey(n int64) string       { return "rating:" + strconv.FormatInt(n, 10) }
func TournamentCountKey(n int64) string {
	return "tournament_count:" + strconv.FormatInt(n, 10)
}
func PartnersKey(n int64) string  { return "partners:" + strconv.FormatInt(n, 10) }
func OpponentsKey(n int64) string { return "opponents:" + strconv.FormatInt(n, 10) }

func TierKey(tier string) string       { return "tier:" + tier }
func TournamentKey(id string) string   { return "tournament:" + id }
func ChampionKey(id string) string     { return "champion:" + id }
func PodiumKey(id string) string       { return "podium:" + id }
func SeasonMemberKey(id string) string { return "season_member:" + id }
func SeasonChampionKey(id string) string {
	return "season_champion:" + id
}
func SeasonPodiumKey(id string) string { return "season_podium:" + id }

// ── Judul tampilan ────────────────────────────────────────────────────────

var sessionCountTitles = map[int64]string{10: "Rajin", 25: "Setia", 50: "Veteran", 100: "Legenda"}
var streakTitles = map[int64]string{5: "Konsisten", 10: "Tanpa Putus", 25: "Tak Terhentikan"}
var gamesTitles = map[int64]string{10: "Pemanasan", 50: "Rutin Main", 100: "Seratus Game", 250: "Mesin Lapangan"}
var winsTitles = map[int64]string{10: "Sepuluh Menang", 50: "Kolektor Menang", 100: "Sultan Menang", 250: "Tak Terbendung"}
var tournamentCountTitles = map[int64]string{1: "Kompetitor", 5: "Langganan Turnamen", 10: "Veteran Turnamen"}
var partnerTitles = map[int64]string{10: "Konektor", 25: "Jaringan Luas", 50: "Sosialita"}
var opponentTitles = map[int64]string{25: "Teruji", 50: "Veteran Laga"}

func atoiMeta(meta map[string]string, key string) int64 {
	n, _ := strconv.ParseInt(meta[key], 10, 64)
	return n
}

// DescribeAchievement — judul + detail untuk ditampilkan. `value` dipakai
// achievement rekor (angka terbaru), `meta` menyimpan label snapshot
// (nama turnamen, season, tier, dst).
func DescribeAchievement(kind string, key string, value *int64, meta map[string]string) (title, detail string) {
	if meta == nil {
		meta = map[string]string{}
	}
	switch AchievementKind(kind) {
	case AchAttendance:
		switch {
		case key == FirstSessionKey:
			return "Debut", "Sesi pertama"
		case strings.HasPrefix(key, "session_count:"):
			n := atoiMeta(meta, "count")
			return lookup(sessionCountTitles, n), fmt.Sprintf("%d sesi diikuti", n)
		case strings.HasPrefix(key, "streak:"):
			n := atoiMeta(meta, "count")
			return lookup(streakTitles, n), fmt.Sprintf("%d sesi berturut", n)
		case strings.HasPrefix(key, "full_attendance:"):
			return "Hadir Penuh", meta["season"]
		}
	case AchVolume:
		switch {
		case strings.HasPrefix(key, "games:"):
			n := atoiMeta(meta, "count")
			return lookup(gamesTitles, n), fmt.Sprintf("%d game", n)
		case strings.HasPrefix(key, "wins:"):
			n := atoiMeta(meta, "count")
			return lookup(winsTitles, n), fmt.Sprintf("%d kemenangan", n)
		case key == WinRateKey:
			return "Efisien", fmt.Sprintf("Win rate %s%% dari %s game", meta["pct"], meta["min"])
		case key == PerfectKey:
			return "Sempurna", "Menang 30-0"
		case key == MarginKey:
			return "Dominan", "Menang selisih 20+ poin"
		}
	case AchTier:
		return "Naik ke " + meta["tier"], "Breakthrough dari tier sticky"
	case AchRating:
		return "Klub " + meta["rating"], "Peak rating"
	case AchTournament:
		switch {
		case strings.HasPrefix(key, "tournament_count:"):
			n := atoiMeta(meta, "count")
			return lookup(tournamentCountTitles, n), fmt.Sprintf("%d turnamen", n)
		case strings.HasPrefix(key, "champion:"):
			return "Juara " + meta["name"], "Juara turnamen"
		case strings.HasPrefix(key, "podium:"):
			return "Podium " + meta["name"], "Runner-up / juara 3"
		case strings.HasPrefix(key, "tournament:"):
			return meta["name"], "Ikut turnamen"
		}
	case AchSocial:
		switch {
		case strings.HasPrefix(key, "partners:"):
			n := atoiMeta(meta, "count")
			return lookup(partnerTitles, n), fmt.Sprintf("%d partner berbeda", n)
		case strings.HasPrefix(key, "opponents:"):
			n := atoiMeta(meta, "count")
			return lookup(opponentTitles, n), fmt.Sprintf("%d lawan berbeda", n)
		}
	case AchSeason:
		switch {
		case strings.HasPrefix(key, "season_champion:"):
			return "Juara " + meta["season"], "Peringkat 1 akhir season"
		case strings.HasPrefix(key, "season_podium:"):
			return "Podium " + meta["season"], "Peringkat 1-3 akhir season"
		case strings.HasPrefix(key, "season_member:"):
			return "Anak " + meta["season"], "Main di season ini"
		}
	case AchRank:
		if key == EstablishedKey {
			return "Mapan", "RD di bawah 50"
		}
	}
	if value != nil && (key == RecordMargin || key == RecordTopPartner || key == RecordStreak) {
		switch key {
		case RecordMargin:
			if meta["opponent"] == "" {
				return "Margin Terbesar", fmt.Sprintf("%s poin", meta["margin"])
			}
			return "Margin Terbesar", fmt.Sprintf("%s poin vs %s", meta["margin"], meta["opponent"])
		case RecordTopPartner:
			return "Partner Terbaik", fmt.Sprintf("%s game dengan %s", meta["games"], meta["partner"])
		case RecordStreak:
			return "Streak Terpanjang", fmt.Sprintf("%s sesi berturut", meta["count"])
		}
	}
	return key, ""
}

// titles — ambil nilai peta; fallback ke angka supaya tidak kosong.
func lookup(m map[int64]string, n int64) string {
	if v, ok := m[n]; ok {
		return v
	}
	return fmt.Sprintf("%d", n)
}
