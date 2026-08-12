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

type CourtTime struct {
	Start string `json:"start"`
	End   string `json:"end"`
}

type Player struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Gender string `json:"gender"`
	Tier   int    `json:"tier"`
}

type FixMatch struct {
	ID    string     `json:"id"`
	Slots [4]*string `json:"slots"`
}

type ScheduleSlot struct {
	Slot  int       `json:"slot"`
	Court int       `json:"court"`
	TeamA [2]string `json:"teamA"`
	TeamB [2]string `json:"teamB"`
}

type GameScore struct {
	A int `json:"a"`
	B int `json:"b"`
}

// GameKey format "{slot}-{court}".
func GameKey(slot, court int) string {
	return strconv.Itoa(slot) + "-" + strconv.Itoa(court)
}
