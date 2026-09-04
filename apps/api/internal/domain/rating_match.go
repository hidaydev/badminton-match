package domain

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// ── RawMatch / extractor contract (RATING_ENGINE_DESIGN.md §4.7) ──────────
// Kontrak minimal antara extractor (baca sumber) dan pipeline ingest.
// Pemain direpresentasikan dengan NAMA (bukan id) — resolve terjadi di
// pipeline ingest (design §4.3.4).

type PairingStrategy string

const (
	PairingPositional  PairingStrategy = "positional"   // format team: counterpart langsung
	PairingTeamAverage PairingStrategy = "team_average" // classic/random: vs semua lawan
)

// KindSpec — entri kind registry (design §4.7). Extractor + konfigurasi
// format baru = tambah entri di sini.
type KindSpec struct {
	Name          string // 'session' | 'tournament_classic' | 'tournament_team'
	DefaultTarget int    // 21 / 30 / 42
	Pairing       PairingStrategy
	PlayerCount   int // 2 (singles) / 4 (doubles) / 6 (partai) — informasi
}

var KindRegistry = map[string]KindSpec{
	"session":            {Name: "session", DefaultTarget: 21, Pairing: PairingTeamAverage, PlayerCount: 4},
	"tournament_classic": {Name: "tournament_classic", DefaultTarget: 21, Pairing: PairingTeamAverage, PlayerCount: 4},
	"tournament_team":    {Name: "tournament_team", DefaultTarget: 30, Pairing: PairingPositional, PlayerCount: 6},
}

func (k KindSpec) Valid() bool {
	_, ok := KindRegistry[k.Name]
	return ok
}

// RawPlayer — satu pemain dalam sebuah game.
type RawPlayer struct {
	Name        string `json:"name"`        // nama sumber (canonical nanti)
	Placeholder bool   `json:"placeholder"` // pattern placeholder (free/tbd/dst)
	Team        string `json:"team"`        // 'A' | 'B'
	Position    int    `json:"position"`    // partai index (team format) / 0
	Absent      bool   `json:"absent"`      // is_absent (game ini void bila ada)
}

// RawMatch — satu game siap diproses.
type RawMatch struct {
	StableGameID string      `json:"stable_game_id"`
	Date         string      `json:"date"` // yyyy-mm-dd (tanggal SUMBER — basis RD growth)
	Kind         string      `json:"kind"`
	SourceID     string      `json:"source_id"`
	Title        string      `json:"title"`
	GameOrder    string      `json:"game_order"` // (slot,court) / partai index — deterministik
	ScoreA       int         `json:"score_a"`
	ScoreB       int         `json:"score_b"`
	Target       int         `json:"target"`
	Phase        string      `json:"phase"` // 'group'|'qf'|'sf'|'3rd'|'final'|'regular'
	Players      []RawPlayer `json:"players"`
}

// Void — game void bila memuat ≥1 pemain absent (design §4.1/§8).
func (m *RawMatch) Void() bool {
	for _, p := range m.Players {
		if p.Absent {
			return true
		}
	}
	return false
}

// PlayersByTeam — pemain tim A/B (bukan placeholder, bukan absent).
func (m *RawMatch) PlayersByTeam(team string) []RawPlayer {
	out := []RawPlayer{}
	for _, p := range m.Players {
		if p.Team == team && !p.Placeholder && !p.Absent {
			out = append(out, p)
		}
	}
	return out
}

// PlayersByTeamInclAbsent — pemain tim A/B termasuk yang absent (bukan
// placeholder). Dipakai policy absent_policy=count — absent dihitung normal.
func (m *RawMatch) PlayersByTeamInclAbsent(team string) []RawPlayer {
	out := []RawPlayer{}
	for _, p := range m.Players {
		if p.Team == team && !p.Placeholder {
			out = append(out, p)
		}
	}
	return out
}

// PlaceholdersByTeam — placeholder tim A/B (rate_as_unknown → sintetik 1250/350).
func (m *RawMatch) PlaceholdersByTeam(team string) []RawPlayer {
	out := []RawPlayer{}
	for _, p := range m.Players {
		if p.Team == team && p.Placeholder {
			out = append(out, p)
		}
	}
	return out
}

// teamNames — sorted names tim (untuk match_key).
func (m *RawMatch) teamNames(team string) []string {
	names := []string{}
	for _, p := range m.Players {
		if p.Team == team {
			names = append(names, p.Name)
		}
	}
	sort.Strings(names)
	return names
}

// MatchKey — identitas STABIL: kind|source_id|stable_game_id|teams|scores|
// target|phase|game_order. Nama placeholder ikut (identitasnya nama).
// Design §4.1.
func (m *RawMatch) MatchKey() string {
	h := sha256.New()
	parts := []string{
		m.Kind, m.SourceID, m.StableGameID,
		strings.Join(m.teamNames("A"), ","),
		strings.Join(m.teamNames("B"), ","),
		fmt.Sprintf("%d", m.ScoreA), fmt.Sprintf("%d", m.ScoreB),
		fmt.Sprintf("%d", m.Target), m.Phase, m.GameOrder,
	}
	for _, p := range parts {
		h.Write([]byte(p))
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))
}

// SourceFingerprint — hash kanonis seluruh match list sumber (diurutkan
// deterministik). Design §4.4. Berbasis NAMA (resolve → id deterministik).
func SourceFingerprint(matches []RawMatch) (string, error) {
	type canonical struct {
		StableGameID string   `json:"sg"`
		GameOrder    string   `json:"go"`
		ScoreA       int      `json:"a"`
		ScoreB       int      `json:"b"`
		Target       int      `json:"t"`
		Phase        string   `json:"p"`
		TeamA        []string `json:"A"`
		TeamB        []string `json:"B"`
	}
	list := make([]canonical, 0, len(matches))
	for _, m := range matches {
		list = append(list, canonical{
			StableGameID: m.StableGameID,
			GameOrder:    m.GameOrder,
			ScoreA:       m.ScoreA,
			ScoreB:       m.ScoreB,
			Target:       m.Target,
			Phase:        m.Phase,
			TeamA:        m.teamNames("A"),
			TeamB:        m.teamNames("B"),
		})
	}
	// sort: game_order adalah identitas urutan deterministik dalam sumber
	sort.Slice(list, func(i, j int) bool { return list[i].GameOrder < list[j].GameOrder })
	raw, err := json.Marshal(list)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), nil
}

// SortMatchesByOrder — urut deterministik sesuai (game_order) untuk sumber
// tunggal; pipeline memakai urutan global (date, created_at, source_id, game_order).
func SortMatchesByOrder(matches []RawMatch) {
	sort.Slice(matches, func(i, j int) bool { return matches[i].GameOrder < matches[j].GameOrder })
}
