// Package domain — tipe domain snapshot session (kontrak CloudSnapshot frontend).
// Di-port dari src/types + src/utils/sessionSnapshot.ts (badminton-match).
package domain

import "strconv"

// CloudSnapshot — representasi lengkap satu session (kontrak frontend).
type CloudSnapshot struct {
	Version       *int                 `json:"version,omitempty"`
	Session       SessionConfig        `json:"session"`
	Players       []Player             `json:"players"`
	FixMatches    []FixMatch           `json:"fixMatches"`
	Schedule      []ScheduleSlot       `json:"schedule"`
	PlayedGames   []string             `json:"playedGames"`
	GameScores    map[string]GameScore `json:"gameScores"`
	AbsentPlayers []string             `json:"absentPlayers,omitempty"`
}

// SessionConfig — konfigurasi sesi (judul, tanggal, court, slot, dst).
type SessionConfig struct {
	Title        string      `json:"title"`
	Date         string      `json:"date"`
	Courts       int         `json:"courts"`
	SessionStart string      `json:"sessionStart"`
	SlotMinutes  int         `json:"slotMinutes"`
	CourtTimes   []CourtTime `json:"courtTimes"`
	PlayerCount  int         `json:"playerCount"`
	CourtNames   []string    `json:"courtNames"`
	Locked       bool        `json:"locked"`
}

// CourtTime — rentang waktu satu court (start–end).
type CourtTime struct {
	Start string `json:"start"`
	End   string `json:"end"`
}

// Player — pemain dalam session (id, nama, gender, tier).
type Player struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Gender string `json:"gender"`
	Tier   int    `json:"tier"`
}

// FixMatch — pertandingan fix (non-rotasi) dengan 4 slot pemain.
type FixMatch struct {
	ID    string     `json:"id"`
	Slots [4]*string `json:"slots"`
}

// ScheduleSlot — satu game terjadwal (slot + court + kedua tim).
type ScheduleSlot struct {
	Slot  int       `json:"slot"`
	Court int       `json:"court"`
	TeamA [2]string `json:"teamA"`
	TeamB [2]string `json:"teamB"`
}

// GameScore — skor satu game (A vs B).
type GameScore struct {
	A int `json:"a"`
	B int `json:"b"`
}

// GameKey format "{slot}-{court}".
func GameKey(slot, court int) string {
	return strconv.Itoa(slot) + "-" + strconv.Itoa(court)
}
