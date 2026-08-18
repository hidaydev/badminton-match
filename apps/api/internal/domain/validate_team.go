package domain

import (
	"errors"
	"strings"
)

// ── Validasi tournament format TIM ─────────────────────────────────────────
// Aturan (spesifikasi):
//   - 6 tim × 6 pemain, tiap tim tepat 6 kelas unik (A+/A/B+/B+/C+/C)
//   - Nama pemain non-blank & unik antar-tim (registrasi global)
//   - Fase grup: 0 (belum undian) atau 9 team-match; tiap tim muncul tepat 3×,
//     tanpa melawan diri sendiri, tanpa duplikat lawan
//   - Skor partai: keduanya null (belum main) atau keduanya ada;
//     grup → pemenang tepat 30 (loser ≤29); final → pemenang tepat 42 (loser ≤41)
//   - Final: 0 atau 1 team-match; team refs valid

// ValidateTeamTournament — periksa invariant snapshot team. Error pertama
// ditemui dikembalikan (urutan cek deterministik).
func ValidateTeamTournament(snap *TeamTournamentSnapshot) error {
	if snap == nil {
		return errors.New("team tournament snapshot must not be null")
	}
	if strings.TrimSpace(snap.Name) == "" {
		return errors.New("tournament snapshot name must not be blank")
	}
	if snap.Date == "" {
		return errors.New("tournament snapshot date must not be blank")
	}

	// ── teams: tepat 6, id unik, 6 pemain dengan 6 kelas unik ────────────
	if len(snap.Teams) != 6 {
		return errors.New("team tournament must contain exactly 6 teams")
	}
	teamSet := make(map[string]struct{}, 6)
	nameSet := make(map[string]struct{}) // player names unik antar-tim
	for _, t := range snap.Teams {
		if strings.TrimSpace(t.ID) == "" {
			return errors.New("team id must not be blank")
		}
		if _, dup := teamSet[t.ID]; dup {
			return errors.New("team ids must be unique")
		}
		teamSet[t.ID] = struct{}{}
		if strings.TrimSpace(t.Name) == "" {
			return errors.New("team name must not be blank")
		}
		if len(t.Players) != 6 {
			return errors.New("each team must contain exactly 6 players")
		}
		clsSeen := map[string]struct{}{}
		for _, p := range t.Players {
			if strings.TrimSpace(p.Name) == "" {
				return errors.New("team player name must not be blank")
			}
			if !isTeamClass(p.Cls) {
				return errors.New("team player class must be one of A+/A/B+/B/C+/C")
			}
			if _, dup := clsSeen[p.Cls]; dup {
				return errors.New("each team must contain each class exactly once")
			}
			clsSeen[p.Cls] = struct{}{}
			norm := NormalizePlayerName(p.Name)
			if _, dup := nameSet[norm]; dup {
				return errors.New("player names must be unique across the tournament")
			}
			nameSet[norm] = struct{}{}
		}
	}

	// ── matches ───────────────────────────────────────────────────────────
	matchSet := make(map[string]struct{}, len(snap.Matches))
	appear := map[string]int{} // team id → jumlah kemunculan di fase grup
	paired := map[string]struct{}{}
	finalCount := 0
	for _, m := range snap.Matches {
		if strings.TrimSpace(m.ID) == "" {
			return errors.New("team match id must not be blank")
		}
		if _, dup := matchSet[m.ID]; dup {
			return errors.New("team match ids must be unique")
		}
		matchSet[m.ID] = struct{}{}
		if m.Phase != "group" && m.Phase != "final" {
			return errors.New("team match phase must be group or final")
		}
		if m.TeamA == "" || m.TeamB == "" {
			return errors.New("team match must reference two teams")
		}
		if m.TeamA == m.TeamB {
			return errors.New("team match must not pair a team with itself")
		}
		if _, ok := teamSet[m.TeamA]; !ok {
			return errors.New("team match references unknown team")
		}
		if _, ok := teamSet[m.TeamB]; !ok {
			return errors.New("team match references unknown team")
		}
		if len(m.Partai) != 3 {
			return errors.New("each team match must contain exactly 3 partai")
		}
		if m.Phase == "group" {
			appear[m.TeamA]++
			appear[m.TeamB]++
			key := pairKey(m.TeamA, m.TeamB)
			if _, dup := paired[key]; dup {
				return errors.New("group phase must not repeat a pairing")
			}
			paired[key] = struct{}{}
		} else {
			finalCount++
		}
		for _, pt := range m.Partai {
			if err := validateTeamPartai(pt, m.Phase); err != nil {
				return err
			}
		}
	}
	if finalCount > 1 {
		return errors.New("team tournament must contain at most 1 final match")
	}
	groupCount := len(snap.Matches) - finalCount
	if groupCount != 0 && groupCount != 9 {
		return errors.New("team tournament must contain 0 (undrawn) or 9 group matches")
	}
	if groupCount == 9 {
		for _, t := range snap.Teams {
			if appear[t.ID] != 3 {
				return errors.New("each team must play exactly 3 group matches")
			}
		}
	}
	return nil
}

// validateTeamPartai — skor per partai: keduanya null atau keduanya ada;
// grup → salah satu tepat 30 (lain ≤29); final → salah satu tepat 42 (lain ≤41).
func validateTeamPartai(pt TeamPartai, phase string) error {
	if pt.ScoreA == nil && pt.ScoreB == nil {
		return nil
	}
	if pt.ScoreA == nil || pt.ScoreB == nil {
		return errors.New("team match partai must have both scores or none")
	}
	a, b := *pt.ScoreA, *pt.ScoreB
	if a == b {
		return errors.New("team match partai scores must not be equal (no deuce)")
	}
	target := 30
	if phase == "final" {
		target = 42
	}
	winner, loser := a, b
	if b > a {
		winner, loser = b, a
	}
	if winner != target || loser > target-1 || loser < 0 || winner < 0 {
		return errors.New("team match partai winner must reach the target exactly (30 group / 42 final)")
	}
	return nil
}

func isTeamClass(cls string) bool {
	for _, c := range TeamClasses {
		if cls == c {
			return true
		}
	}
	return false
}

// pairKey — kunci pairing tanpa urutan (A-B dan B-A sama).
func pairKey(a, b string) string {
	if a < b {
		return a + "\x00" + b
	}
	return b + "\x00" + a
}
