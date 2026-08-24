package domain

import (
	"fmt"
	"strings"
	"time"
)

// ── Validasi snapshot session ──────────────────────────────────────────────
// Port dari bm.validate_session_snapshot (SQL, migrations/000001_functions.sql
// baris 1763–2082). Setiap invariant dipertahankan 1:1 — tidak ada aturan baru,
// tidak ada yang dilonggarkan.
//
// Catatan port (perbedaan struktural JSON → tipe Go):
//   - Cek "harus array/object" tidak perlu: decode JSON ke struct sudah
//     menjamin bentuk tersebut.
//   - gender kosong ("") DITOLAK — di SQL, key gender yang ABSEN di-default ke
//     'M'; string kosong tetap gagal. Go tidak bisa membedakan absent vs kosong,
//     jadi kami konservatif: kosong = invalid. Frontend selalu mengirim gender.
//   - tier 0 (absent/kosong) DITOLAK — di SQL di-default ke 1. Sama: konservatif.

// ValidateSnapshot — periksa seluruh invariant snapshot. Error pertama yang
// ditemui dikembalikan (urutan cek mirror SQL). Nil = valid.
func ValidateSnapshot(snap *CloudSnapshot) error {
	if snap == nil {
		return fmt.Errorf("session snapshot must not be null")
	}

	// ── session ─────────────────────────────────────────────────────────
	if snap.Session.Date == "" {
		return fmt.Errorf("session snapshot.session.date must not be blank")
	}
	if _, err := time.Parse("2006-01-02", snap.Session.Date); err != nil {
		return fmt.Errorf("session snapshot.session.date must be a valid date: %v", err)
	}
	if snap.Session.SessionStart != "" {
		if _, err := time.Parse("15:04", snap.Session.SessionStart); err != nil {
			return fmt.Errorf("session snapshot.session.sessionStart must be a valid time: %v", err)
		}
	}
	// slotMinutes: jika ada (non-zero) harus positif. Absen (0) di-default ke 20
	// oleh write-path (mirror coalesce(nullif(slotMinutes,'')::integer, 20)).
	if snap.Session.SlotMinutes < 0 {
		return fmt.Errorf("session snapshot.session.slotMinutes must be positive")
	}

	// ── players ─────────────────────────────────────────────────────────
	for _, p := range snap.Players {
		if strings.TrimSpace(p.ID) == "" || strings.TrimSpace(p.Name) == "" {
			return fmt.Errorf("session players must contain non-blank id/name and valid gender/tier values")
		}
		if p.Gender != "M" && p.Gender != "F" {
			return fmt.Errorf("session players must contain non-blank id/name and valid gender/tier values")
		}
		if p.Tier < 1 || p.Tier > 8 {
			return fmt.Errorf("session players must contain non-blank id/name and valid gender/tier values")
		}
	}
	if len(snap.Players) < 4 || len(snap.Players) > 60 {
		return fmt.Errorf("session players must contain between 4 and 60 players")
	}
	seen := map[string]bool{}
	for _, p := range snap.Players {
		if seen[p.ID] {
			return fmt.Errorf("session player ids must be unique")
		}
		seen[p.ID] = true
	}
	if snap.Session.PlayerCount != 0 && snap.Session.PlayerCount != len(snap.Players) {
		return fmt.Errorf("session snapshot.session.playerCount must match players length")
	}
	if snap.Session.PlayerCount < 4 || snap.Session.PlayerCount > 60 {
		return fmt.Errorf("session snapshot.session.playerCount must be between 4 and 60")
	}
	if snap.Session.Courts < 0 {
		return fmt.Errorf("session snapshot.session.courts must be non-negative")
	}

	// ── courtTimes ──────────────────────────────────────────────────────
	for _, ct := range snap.Session.CourtTimes {
		if ct.Start == "" || ct.End == "" {
			return fmt.Errorf("session courtTimes entries must contain valid ascending start/end times")
		}
		start, err1 := time.Parse("15:04", ct.Start)
		end, err2 := time.Parse("15:04", ct.End)
		if err1 != nil || err2 != nil || !end.After(start) {
			return fmt.Errorf("session courtTimes entries must contain valid ascending start/end times")
		}
	}

	// ── schedule ────────────────────────────────────────────────────────
	gameKeys := make(map[string]struct{}, len(snap.Schedule))
	for _, g := range snap.Schedule {
		if g.Slot < 0 || g.Court < 0 || len(g.TeamA) != 2 || len(g.TeamB) != 2 {
			return fmt.Errorf("session schedule entries must have non-negative slot/court and 2 players per team")
		}
		key := GameKey(g.Slot, g.Court)
		if _, dup := gameKeys[key]; dup {
			return fmt.Errorf("session schedule must not repeat slot/court combinations")
		}
		gameKeys[key] = struct{}{}
	}

	// refs yang valid (trim) dari players
	playerRefs := make(map[string]struct{}, len(snap.Players))
	for _, p := range snap.Players {
		playerRefs[trimPlayerRef(p.ID)] = struct{}{}
	}
	// schedule: semua ref harus dikenal + non-blank
	for _, g := range snap.Schedule {
		all := [4]string{g.TeamA[0], g.TeamA[1], g.TeamB[0], g.TeamB[1]}
		distinct := map[string]struct{}{}
		for _, ref := range all {
			ref = trimPlayerRef(ref)
			if ref == "" {
				return fmt.Errorf("session schedule must only reference known non-blank player ids")
			}
			if _, ok := playerRefs[ref]; !ok {
				return fmt.Errorf("session schedule must only reference known non-blank player ids")
			}
			distinct[ref] = struct{}{}
		}
		if len(distinct) != 4 {
			return fmt.Errorf("session schedule entries must not repeat a player within the same game")
		}
	}

	// totalGames: key ini TIDAK di-decode ke SessionConfig — invariant
	// "totalGames harus sama dengan panjang schedule" terjamin oleh konstruksi
	// (totalGames selalu dihitung dari schedule, tidak pernah disimpan).

	// ── fixMatches ──────────────────────────────────────────────────────
	seenFix := map[string]struct{}{}
	for i, fm := range snap.FixMatches {
		legacyRef := fm.ID
		if legacyRef == "" {
			legacyRef = fmt.Sprintf("fix-%d", i)
		}
		if _, dup := seenFix[legacyRef]; dup {
			return fmt.Errorf("session fixMatches ids must be unique")
		}
		seenFix[legacyRef] = struct{}{}

		if len(fm.Slots) > 4 {
			return fmt.Errorf("session fixMatches entries must contain a slots array with at most 4 items")
		}
		for _, slot := range fm.Slots {
			// Slot kosong = open slot (mirror SQL nullif(trim(slot), '') → NULL:
			// tidak wajib reference pemain).
			if slot == nil {
				continue
			}
			ref := trimPlayerRef(*slot)
			if ref == "" {
				continue
			}
			if _, ok := playerRefs[ref]; !ok {
				return fmt.Errorf("session fixMatches must only reference known player ids")
			}
		}
	}

	// ── absentPlayers ───────────────────────────────────────────────────
	seenAbsent := map[string]struct{}{}
	for _, id := range snap.AbsentPlayers {
		ref := trimPlayerRef(id)
		if ref == "" {
			return fmt.Errorf("session absentPlayers must only reference known non-blank player ids")
		}
		if _, ok := playerRefs[ref]; !ok {
			return fmt.Errorf("session absentPlayers must only reference known non-blank player ids")
		}
		if _, dup := seenAbsent[ref]; dup {
			return fmt.Errorf("session absentPlayers must not contain duplicates")
		}
		seenAbsent[ref] = struct{}{}
	}

	// ── playedGames + gameScores ────────────────────────────────────────
	seenPlayed := map[string]struct{}{}
	for _, key := range snap.PlayedGames {
		if _, ok := gameKeys[key]; !ok {
			return fmt.Errorf("session playedGames must only reference scheduled games")
		}
		if _, dup := seenPlayed[key]; dup {
			return fmt.Errorf("session playedGames must not contain duplicates")
		}
		seenPlayed[key] = struct{}{}
	}
	for key, score := range snap.GameScores {
		if _, ok := gameKeys[key]; !ok {
			return fmt.Errorf("session gameScores must reference scheduled games and contain valid non-tied scores")
		}
		if _, played := seenPlayed[key]; !played {
			return fmt.Errorf("session gameScores must only exist for games listed in playedGames")
		}
		if score.A < 0 || score.A > 99 || score.B < 0 || score.B > 99 || score.A == score.B {
			return fmt.Errorf("session gameScores must reference scheduled games and contain valid non-tied scores")
		}
	}

	return nil
}

// trimPlayerRef — padanan trim() di SQL untuk player ref (lihat
// trim(player_item.value->>'id') di validate_session_snapshot).
func trimPlayerRef(ref string) string {
	return strings.TrimSpace(ref)
}
