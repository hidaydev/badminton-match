package domain

import (
	"errors"
	"strings"
	"time"
)

// TournamentSnapshot — kontrak tournament (mirror TournamentSnapshot di
// src/utils/tournament.ts).
type TournamentSnapshot struct {
	Version *int                `json:"version,omitempty"`
	Format  string              `json:"format"`
	Name    string              `json:"name"`
	Date    string              `json:"date"`
	Pairs   []TournamentPair    `json:"pairs"`
	Groups  map[string][]string `json:"groups"`
	Matches []TournamentMatch   `json:"matches"`
}

// TournamentPair — pasangan pemain dalam tournament.
type TournamentPair struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// TournamentMatch — satu pertandingan bracket tournament.
type TournamentMatch struct {
	ID      string  `json:"id"`
	Phase   string  `json:"phase"`
	GroupID string  `json:"groupId,omitempty"`
	PairAID *string `json:"pairAId"`
	PairBID *string `json:"pairBId"`
	ScoreA  *int    `json:"scoreA"`
	ScoreB  *int    `json:"scoreB"`
	PICName *string `json:"picName,omitempty"`
}

// validTournamentPhases — phase yang diterima (mirror CHECK di SQL).
var validTournamentPhases = map[string]bool{
	"group": true, "qf": true, "sf": true, "3rd": true, "final": true,
}

// ValidateTournamentSnapshot — port bm.validate_tournament_snapshot (SQL).
// Setiap invariant dipertahankan 1:1. Error pertama yang ditemui dikembalikan.
func ValidateTournamentSnapshot(snap *TournamentSnapshot) error {
	if snap == nil {
		return errors.New("tournament snapshot must not be null")
	}
	if strings.TrimSpace(snap.Name) == "" {
		return errors.New("tournament snapshot name must not be blank")
	}
	if snap.Date == "" {
		return errors.New("tournament snapshot date must not be blank")
	}
	if _, err := time.Parse("2006-01-02", snap.Date); err != nil {
		return errors.New("tournament snapshot date must be a valid date")
	}

	// ── pairs: tepat 16, id/name non-blank, id unik ─────────────────────
	if len(snap.Pairs) != 16 {
		return errors.New("tournament snapshot must contain exactly 16 pairs")
	}
	pairSet := make(map[string]struct{}, 16)
	for _, p := range snap.Pairs {
		if strings.TrimSpace(p.ID) == "" || strings.TrimSpace(p.Name) == "" {
			return errors.New("tournament pairs must contain non-blank id and name fields")
		}
		if _, dup := pairSet[p.ID]; dup {
			return errors.New("tournament pair ids must be unique")
		}
		pairSet[p.ID] = struct{}{}
	}

	// ── groups: tepat 4 key A/B/C/D, tiap array 0 atau 4, refs dikenal ──
	if len(snap.Groups) != 4 {
		return errors.New("tournament groups must contain exactly 4 keys")
	}
	groupedSet := make(map[string]struct{})
	for _, g := range []string{"A", "B", "C", "D"} {
		arr, ok := snap.Groups[g]
		if !ok {
			return errors.New("tournament groups must contain keys A, B, C, and D")
		}
		if len(arr) != 0 && len(arr) != 4 {
			return errors.New("each tournament group must contain either 0 or 4 pair ids")
		}
		for _, pid := range arr {
			if strings.TrimSpace(pid) == "" {
				return errors.New("tournament groups must only reference known non-blank pair ids")
			}
			if _, known := pairSet[pid]; !known {
				return errors.New("tournament groups must only reference known non-blank pair ids")
			}
			if _, dup := groupedSet[pid]; dup {
				return errors.New("tournament group assignments must not repeat pair ids")
			}
			groupedSet[pid] = struct{}{}
		}
	}

	// ── matches: tepat 32 (24 group, 4 qf, 2 sf, 1 3rd, 1 final) ────────
	if len(snap.Matches) != 32 {
		return errors.New("tournament snapshot must contain exactly 32 matches")
	}
	phaseCount := map[string]int{}
	seenMatch := make(map[string]struct{}, 32)
	for _, m := range snap.Matches {
		if strings.TrimSpace(m.ID) == "" || !validTournamentPhases[m.Phase] {
			return errors.New("tournament matches must contain non-blank id and valid phase fields")
		}
		if _, dup := seenMatch[m.ID]; dup {
			return errors.New("tournament match ids must be unique")
		}
		seenMatch[m.ID] = struct{}{}
		phaseCount[m.Phase]++
	}
	if phaseCount["group"] != 24 || phaseCount["qf"] != 4 || phaseCount["sf"] != 2 ||
		phaseCount["3rd"] != 1 || phaseCount["final"] != 1 {
		return errors.New("tournament snapshot must contain 24 group matches, 4 qf, 2 sf, 1 third-place, and 1 final")
	}

	// ── pair refs di matches: dikenal & distinct ─────────────────────────
	for _, m := range snap.Matches {
		if m.PairAID != nil && strings.TrimSpace(*m.PairAID) != "" {
			if _, known := pairSet[*m.PairAID]; !known {
				return errors.New("tournament matches must reference known distinct pair ids")
			}
		}
		if m.PairBID != nil && strings.TrimSpace(*m.PairBID) != "" {
			if _, known := pairSet[*m.PairBID]; !known {
				return errors.New("tournament matches must reference known distinct pair ids")
			}
		}
		if m.PairAID != nil && m.PairBID != nil &&
			strings.TrimSpace(*m.PairAID) != "" && *m.PairAID == *m.PairBID {
			return errors.New("tournament matches must reference known distinct pair ids")
		}
	}
	return nil
}
