package domain

import (
	"errors"
	"fmt"
)

var (
	errScoresEqual    = errors.New("scores cannot be equal")
	errScoresNegative = errors.New("scores cannot be negative")
	errScoresTooHigh  = errors.New("scores must be between 0 and 99")
)

// ValidateScore — aturan skor: tidak boleh sama, tidak boleh negatif, max 99
// (konsisten dengan CHECK constraint scheduled_games di DB).
func ValidateScore(a, b int) error {
	if a == b {
		return errScoresEqual
	}
	if a < 0 || b < 0 {
		return errScoresNegative
	}
	if a > 99 || b > 99 {
		return errScoresTooHigh
	}
	return nil
}

// ClearScore — hapus skor game dan tandai un-played. Tidak seperti toggle:
// game yang belum played tetap tidak played (tidak menambah playedGames).
func (s *CloudSnapshot) ClearScore(key string) {
	s.PlayedGames = removeString(s.PlayedGames, key)
	delete(s.GameScores, key)
}

// SwapTarget — tukar dua pemain (mirror SwapTarget di swap.ts).
type SwapTarget struct {
	Slot     int    `json:"slot"`
	Court    int    `json:"court"`
	PlayerID string `json:"playerId"`
	Team     string `json:"team"`  // "A" | "B"
	Index    int    `json:"index"` // 0 | 1
}

// Validate — memastikan target aman (cegah panic index out of range).
func (t SwapTarget) Validate() error {
	if t.Team != "A" && t.Team != "B" {
		return fmt.Errorf("team must be A or B, got %q", t.Team)
	}
	if t.Index != 0 && t.Index != 1 {
		return fmt.Errorf("index must be 0 or 1, got %d", t.Index)
	}
	if t.PlayerID == "" {
		return errors.New("playerId is required")
	}
	return nil
}

// TeamSwapTarget — tukar dua team (mirror TeamSwapTarget di swap.ts).
type TeamSwapTarget struct {
	Slot  int    `json:"slot"`
	Court int    `json:"court"`
	Team  string `json:"team"` // "A" | "B"
}

// Validate — memastikan team valid.
func (t TeamSwapTarget) Validate() error {
	if t.Team != "A" && t.Team != "B" {
		return fmt.Errorf("team must be A or B, got %q", t.Team)
	}
	return nil
}

// SlotSwapTarget — tukar dua slot game (mirror SlotSwapTarget di slotSwap.ts).
type SlotSwapTarget struct {
	Slot  int `json:"slot"`
	Court int `json:"court"`
}

// Validate — slot/court tidak boleh negatif.
func (t SlotSwapTarget) Validate() error {
	if t.Slot < 0 || t.Court < 0 {
		return errors.New("slot and court must be >= 0")
	}
	return nil
}

// SetScore — set skor game + tandai played. Mengembalikan error kalau skor invalid.
func (s *CloudSnapshot) SetScore(key string, a, b int) error {
	if err := ValidateScore(a, b); err != nil {
		return err
	}
	if s.GameScores == nil {
		s.GameScores = map[string]GameScore{}
	}
	s.GameScores[key] = GameScore{A: a, B: b}
	s.PlayedGames = appendUnique(s.PlayedGames, key)
	return nil
}

// TogglePlayed — toggle status played; saat di-unplay, skor ikut dihapus.
func (s *CloudSnapshot) TogglePlayed(key string) {
	idx := indexOf(s.PlayedGames, key)
	if idx >= 0 {
		s.PlayedGames = append(s.PlayedGames[:idx], s.PlayedGames[idx+1:]...)
		delete(s.GameScores, key)
		return
	}
	s.PlayedGames = append(s.PlayedGames, key)
}

// SetAbsent — set daftar pemain absent.
func (s *CloudSnapshot) SetAbsent(next []string) {
	s.AbsentPlayers = next
}

// RenamePlayer — rename nama pemain dalam players array (bukan schedule).
func (s *CloudSnapshot) RenamePlayer(playerID, newName string) {
	for i := range s.Players {
		if s.Players[i].ID == playerID {
			s.Players[i].Name = newName
			return
		}
	}
}

// SwapPlayers — tukar dua pemain antar game.
func (s *CloudSnapshot) SwapPlayers(t1, t2 SwapTarget) {
	s.Schedule = ApplySwap(s.Schedule, t1, t2)
}

// SwapTeams — tukar dua team antar game.
func (s *CloudSnapshot) SwapTeams(t1, t2 TeamSwapTarget) {
	s.Schedule = ApplyTeamSwap(s.Schedule, t1, t2)
}

// SwapSlots — tukar dua slot; playedGames & gameScores ikut di-migrate.
func (s *CloudSnapshot) SwapSlots(g1, g2 SlotSwapTarget) {
	s.Schedule = ApplySlotSwap(s.Schedule, g1, g2)
	s.PlayedGames = SwapKeyInList(s.PlayedGames, g1, g2)
	s.GameScores = SwapKeys(s.GameScores, g1, g2)
}

// ── Schedule-level (pure) ────────────────────────────────────────────────

// ApplySwap — tukar dua pemain antar game (pure, tanpa mutasi input).
func ApplySwap(schedule []ScheduleSlot, t1, t2 SwapTarget) []ScheduleSlot {
	if t1.Slot == t2.Slot && t1.Court == t2.Court && t1.Team == t2.Team && t1.Index == t2.Index {
		return schedule
	}
	if t1.PlayerID == t2.PlayerID {
		return schedule
	}
	sameGame := t1.Slot == t2.Slot && t1.Court == t2.Court
	out := make([]ScheduleSlot, len(schedule))
	copy(out, schedule)
	for i := range out {
		s := &out[i]
		if s.Slot == t1.Slot && s.Court == t1.Court {
			setPlayer(s, t1.Team, t1.Index, t2.PlayerID)
			if sameGame {
				setPlayer(s, t2.Team, t2.Index, t1.PlayerID)
			}
			continue
		}
		if !sameGame && s.Slot == t2.Slot && s.Court == t2.Court {
			setPlayer(s, t2.Team, t2.Index, t1.PlayerID)
		}
	}
	return out
}

// ApplyTeamSwap — tukar dua team antar game (pure, tanpa mutasi input).
func ApplyTeamSwap(schedule []ScheduleSlot, t1, t2 TeamSwapTarget) []ScheduleSlot {
	if t1.Slot == t2.Slot && t1.Court == t2.Court && t1.Team == t2.Team {
		return schedule
	}
	var game1, game2 *ScheduleSlot
	for i := range schedule {
		if schedule[i].Slot == t1.Slot && schedule[i].Court == t1.Court {
			game1 = &schedule[i]
		}
		if schedule[i].Slot == t2.Slot && schedule[i].Court == t2.Court {
			game2 = &schedule[i]
		}
	}
	if game1 == nil || game2 == nil {
		return schedule
	}
	team1 := teamOf(game1, t1.Team)
	team2 := teamOf(game2, t2.Team)
	sameGame := t1.Slot == t2.Slot && t1.Court == t2.Court

	out := make([]ScheduleSlot, len(schedule))
	copy(out, schedule)
	for i := range out {
		s := &out[i]
		if s.Slot == t1.Slot && s.Court == t1.Court {
			setTeam(s, t1.Team, team2)
			if sameGame {
				setTeam(s, t2.Team, team1)
			}
			continue
		}
		if !sameGame && s.Slot == t2.Slot && s.Court == t2.Court {
			setTeam(s, t2.Team, team1)
		}
	}
	return out
}

// ApplySlotSwap — tukar posisi dua slot game (pure, tanpa mutasi input).
func ApplySlotSwap(schedule []ScheduleSlot, g1, g2 SlotSwapTarget) []ScheduleSlot {
	out := make([]ScheduleSlot, len(schedule))
	copy(out, schedule)
	for i := range out {
		s := &out[i]
		if s.Slot == g1.Slot && s.Court == g1.Court {
			s.Slot, s.Court = g2.Slot, g2.Court
		} else if s.Slot == g2.Slot && s.Court == g2.Court {
			s.Slot, s.Court = g1.Slot, g1.Court
		}
	}
	return out
}

// SwapKeys — pindahkan nilai antar key saat slot ditukar (gameScores).
func SwapKeys(m map[string]GameScore, g1, g2 SlotSwapTarget) map[string]GameScore {
	if m == nil {
		return nil
	}
	k1, k2 := GameKey(g1.Slot, g1.Court), GameKey(g2.Slot, g2.Court)
	next := make(map[string]GameScore, len(m))
	for key, v := range m {
		switch key {
		case k1:
			next[k2] = v
		case k2:
			next[k1] = v
		default:
			next[key] = v
		}
	}
	return next
}

// SwapKeyInList — migrate item list saat slot ditukar (playedGames).
func SwapKeyInList(items []string, g1, g2 SlotSwapTarget) []string {
	k1, k2 := GameKey(g1.Slot, g1.Court), GameKey(g2.Slot, g2.Court)
	out := make([]string, len(items))
	for i, key := range items {
		switch key {
		case k1:
			out[i] = k2
		case k2:
			out[i] = k1
		default:
			out[i] = key
		}
	}
	return out
}

// ── helpers ──────────────────────────────────────────────────────────────

func setPlayer(s *ScheduleSlot, team string, index int, playerID string) {
	if team == "A" {
		s.TeamA[index] = playerID
	} else {
		s.TeamB[index] = playerID
	}
}

func teamOf(s *ScheduleSlot, team string) [2]string {
	if team == "A" {
		return s.TeamA
	}
	return s.TeamB
}

func setTeam(s *ScheduleSlot, team string, players [2]string) {
	if team == "A" {
		s.TeamA = players
	} else {
		s.TeamB = players
	}
}

func appendUnique(items []string, key string) []string {
	if indexOf(items, key) >= 0 {
		return items
	}
	return append(items, key)
}

func indexOf(items []string, key string) int {
	for i, k := range items {
		if k == key {
			return i
		}
	}
	return -1
}

func removeString(items []string, key string) []string {
	out := make([]string, 0, len(items))
	for _, k := range items {
		if k != key {
			out = append(out, k)
		}
	}
	return out
}
