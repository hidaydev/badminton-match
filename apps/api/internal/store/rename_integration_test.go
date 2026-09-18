package store

import (
	"context"
	"fmt"
	"testing"
	"time"

	"majadu-api/internal/domain"
)

// TestIntegrationSessionNameUsesCanonical — nama pemain terdaftar di sesi
// di-resolve dari players.canonical_name saat baca, bukan source_name yang
// dibekukan saat publish. Ini skenario "Miqdad (Teman Ismet)" → rename
// "Miqdad": sesi lama langsung menampilkan nama utama tanpa menyentuh data.
//
// source_name tetap catatan mentah (rename TIDAK mengubahnya) supaya
// SourceFingerprint sumber stabil dan re-ingest aman.
//
// Butuh MAJADU_TEST_DATABASE_URL (lihat ratingTestEnv).
func TestIntegrationSessionNameUsesCanonical(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()
	pool := st.pool
	ps := NewPlayerStore(pool, schema)

	suffix := fmt.Sprintf("%d", time.Now().UnixNano())
	oldName := "CanonRead " + suffix + " (alias)"
	newName := "CanonRead " + suffix + " Baru"
	players := []domain.Player{
		{ID: "cn1", Name: oldName, Gender: "M", Tier: 3},
		{ID: "cn2", Name: "CanonRead Two " + suffix, Gender: "M", Tier: 3},
		{ID: "cn3", Name: "CanonRead Three " + suffix, Gender: "M", Tier: 3},
		{ID: "cn4", Name: "CanonRead Four " + suffix, Gender: "M", Tier: 3},
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	defer func() {
		canon := make([]string, 0, len(players)+1)
		canon = append(canon, newName)
		for _, p := range players {
			canon = append(canon, p.Name)
		}
		pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name = ANY($1)`, canon)
	}()

	id := fmt.Sprintf("it-canonread-%d", time.Now().UnixNano())
	defer pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code = $1`, id)

	snap := &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "CanonRead IT", Date: testSessionDate(2), Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: len(players),
			CourtNames:  []string{"C1"},
		},
		Players:     players,
		FixMatches:  []domain.FixMatch{},
		Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"cn1", "cn2"}, TeamB: [2]string{"cn3", "cn4"}}},
		PlayedGames: []string{},
		GameScores:  map[string]domain.GameScore{},
	}
	if _, err := st.Save(ctx, id, snap); err != nil {
		t.Fatalf("save session: %v", err)
	}

	// Sebelum rename: canonical == nama saat publish.
	loaded, err := st.Load(ctx, id)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if got := playerNameByRef(t, loaded, "cn1"); got != oldName {
		t.Fatalf("sebelum rename: name = %q, want %q", got, oldName)
	}

	var pid string
	if err := pool.QueryRow(ctx,
		`SELECT player_id::text FROM `+schema+`.player_aliases WHERE alias_name = $1`,
		domain.NormalizePlayerName(oldName)).Scan(&pid); err != nil {
		t.Fatalf("resolve player: %v", err)
	}
	if err := ps.RenamePlayer(ctx, pid, newName); err != nil {
		t.Fatalf("rename: %v", err)
	}

	// Sesudah rename: Load menampilkan canonical baru, tanpa re-publish / backfill.
	loaded2, err := st.Load(ctx, id)
	if err != nil {
		t.Fatalf("load2: %v", err)
	}
	if got := playerNameByRef(t, loaded2, "cn1"); got != newName {
		t.Fatalf("sesudah rename: name = %q, want %q", got, newName)
	}

	// source_name mentah tidak ikut berubah.
	var raw string
	if err := pool.QueryRow(ctx, `
		SELECT sp.source_name FROM `+schema+`.session_players sp
		JOIN `+schema+`.sessions s ON s.id = sp.session_id
		WHERE s.share_code = $1 AND sp.player_ref = 'cn1'`, id).Scan(&raw); err != nil {
		t.Fatalf("read source_name: %v", err)
	}
	if raw != oldName {
		t.Fatalf("source_name = %q, want unchanged %q", raw, oldName)
	}
}

// playerNameByRef — cari nama pemain berdasarkan player_ref di snapshot.
func playerNameByRef(t *testing.T, snap *domain.CloudSnapshot, ref string) string {
	t.Helper()
	for _, p := range snap.Players {
		if p.ID == ref {
			return p.Name
		}
	}
	t.Fatalf("player ref %q tidak ada di snapshot", ref)
	return ""
}

// TestIntegrationTeamPlayerNameUsesCanonical — sama seperti sesi, nama pemain
// team tournament di-resolve dari players.canonical_name saat baca, bukan
// tournament_team_players.player_name yang dibekukan saat publish.
func TestIntegrationTeamPlayerNameUsesCanonical(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()
	pool := st.pool
	ps := NewPlayerStore(pool, schema)
	ts := NewTournamentStore(pool, schema)

	suffix := fmt.Sprintf("%d", time.Now().UnixNano())
	oldName := "TeamCanon " + suffix + " (alias)"
	newName := "TeamCanon " + suffix + " Baru"

	snap := buildTeamSnapIT()
	snap.Teams[0].Players[0].Name = oldName // kelas A+

	id := "it-teamcanon-" + suffix
	if _, err := ts.TeamSave(ctx, id, snap); err != nil {
		t.Fatalf("team save: %v", err)
	}
	defer func() {
		pool.Exec(ctx, `DELETE FROM `+schema+`.tournaments WHERE share_code = $1`, id)
		pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name = ANY($1)`, []string{oldName, newName})
	}()

	var pid string
	if err := pool.QueryRow(ctx,
		`SELECT player_id::text FROM `+schema+`.player_aliases WHERE alias_name = $1`,
		domain.NormalizePlayerName(oldName)).Scan(&pid); err != nil {
		t.Fatalf("resolve player: %v", err)
	}

	teamNameByCls := func(s *domain.TeamTournamentSnapshot, teamID, cls string) string {
		t.Helper()
		for _, tm := range s.Teams {
			if tm.ID != teamID {
				continue
			}
			for _, p := range tm.Players {
				if p.Cls == cls {
					return p.Name
				}
			}
		}
		t.Fatalf("team %s kelas %s tidak ada", teamID, cls)
		return ""
	}

	if got := teamNameByCls(snap, "t1", "A+"); got != oldName {
		t.Fatalf("sebelum rename: %q, want %q", got, oldName)
	}

	if err := ps.RenamePlayer(ctx, pid, newName); err != nil {
		t.Fatalf("rename: %v", err)
	}

	loaded, err := ts.TeamLoad(ctx, id)
	if err != nil {
		t.Fatalf("team load: %v", err)
	}
	if got := teamNameByCls(loaded, "t1", "A+"); got != newName {
		t.Fatalf("sesudah rename: %q, want %q", got, newName)
	}

	// player_name mentah tidak ikut berubah.
	var raw string
	if err := pool.QueryRow(ctx, `
		SELECT ttp.player_name FROM `+schema+`.tournament_team_players ttp
		JOIN `+schema+`.tournament_teams tt ON tt.id = ttp.team_id
		JOIN `+schema+`.tournaments t ON t.id = tt.tournament_id
		WHERE t.share_code = $1 AND ttp.player_id = $2::uuid`, id, pid).Scan(&raw); err != nil {
		t.Fatalf("read player_name: %v", err)
	}
	if raw != oldName {
		t.Fatalf("player_name = %q, want unchanged %q", raw, oldName)
	}
}

// TestIntegrationSessionSourceNameStableAcrossEdit — regresi: Load() mengembalikan
// canonical_name, jadi Save() balik (mis. unlock → edit → save) TIDAK boleh
// menimpa session_players.source_name. Kolom itu ikut SourceFingerprint; kalau
// tertimpa, re-ingest sumber yang sudah ter-ingest gagal ErrSourceChanged.
func TestIntegrationSessionSourceNameStableAcrossEdit(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()
	pool := st.pool
	ps := NewPlayerStore(pool, schema)

	suffix := fmt.Sprintf("%d", time.Now().UnixNano())
	oldName := "StableSrc " + suffix
	newName := "StableSrc " + suffix + " Baru"
	players := []domain.Player{
		{ID: "ss1", Name: oldName, Gender: "M", Tier: 3},
		{ID: "ss2", Name: "StableSrc Two " + suffix, Gender: "M", Tier: 3},
		{ID: "ss3", Name: "StableSrc Three " + suffix, Gender: "M", Tier: 3},
		{ID: "ss4", Name: "StableSrc Four " + suffix, Gender: "M", Tier: 3},
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	defer func() {
		canon := []string{newName}
		for _, p := range players {
			canon = append(canon, p.Name)
		}
		pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name = ANY($1)`, canon)
	}()

	id := fmt.Sprintf("it-stablesrc-%d", time.Now().UnixNano())
	defer cleanupSession(ctx, st, id)

	// Semua game belum dimainkan → sesi tetap draft (tidak auto-lock).
	snap := &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "StableSrc IT", Date: testSessionDate(2), Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: len(players),
			CourtNames:  []string{"C1"},
		},
		Players:     players,
		FixMatches:  []domain.FixMatch{},
		Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"ss1", "ss2"}, TeamB: [2]string{"ss3", "ss4"}}},
		PlayedGames: []string{},
		GameScores:  map[string]domain.GameScore{},
	}
	if _, err := st.Save(ctx, id, snap); err != nil {
		t.Fatalf("save: %v", err)
	}

	var pid string
	if err := pool.QueryRow(ctx,
		`SELECT player_id::text FROM `+schema+`.player_aliases WHERE alias_name = $1`,
		domain.NormalizePlayerName(oldName)).Scan(&pid); err != nil {
		t.Fatalf("resolve player: %v", err)
	}
	if err := ps.RenamePlayer(ctx, pid, newName); err != nil {
		t.Fatalf("rename: %v", err)
	}

	loaded, err := st.Load(ctx, id)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if got := playerNameByRef(t, loaded, "ss1"); got != newName {
		t.Fatalf("load name = %q, want canonical %q", got, newName)
	}

	// Save balik snapshot hasil Load → source_name MENTAH harus tetap oldName.
	if _, err := st.Save(ctx, id, loaded); err != nil {
		t.Fatalf("save round-trip: %v", err)
	}
	var raw string
	if err := pool.QueryRow(ctx, `
		SELECT sp.source_name FROM `+schema+`.session_players sp
		JOIN `+schema+`.sessions s ON s.id = sp.session_id
		WHERE s.share_code = $1 AND sp.player_ref = 'ss1'`, id).Scan(&raw); err != nil {
		t.Fatalf("read source_name: %v", err)
	}
	if raw != oldName {
		t.Fatalf("source_name tertimpa canonical: %q, want %q", raw, oldName)
	}
}

// TestIntegrationTeamPlayerNameStableAcrossEdit — sama seperti sesi, untuk
// tournament_team_players.player_name (fingerprint team).
func TestIntegrationTeamPlayerNameStableAcrossEdit(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()
	pool := st.pool
	ps := NewPlayerStore(pool, schema)
	ts := NewTournamentStore(pool, schema)

	suffix := fmt.Sprintf("%d", time.Now().UnixNano())
	oldName := "TeamStable " + suffix
	newName := "TeamStable " + suffix + " Baru"

	snap := buildTeamSnapIT()
	snap.Teams[0].Players[0].Name = oldName // kelas A+

	id := "it-teamstable-" + suffix
	created, err := ts.TeamSave(ctx, id, snap)
	if err != nil {
		t.Fatalf("team save: %v", err)
	}
	defer func() {
		pool.Exec(ctx, `DELETE FROM `+schema+`.tournaments WHERE share_code = $1`, id)
		pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name = ANY($1)`, []string{oldName, newName})
	}()

	var pid string
	if err := pool.QueryRow(ctx,
		`SELECT player_id::text FROM `+schema+`.player_aliases WHERE alias_name = $1`,
		domain.NormalizePlayerName(oldName)).Scan(&pid); err != nil {
		t.Fatalf("resolve player: %v", err)
	}
	if err := ps.RenamePlayer(ctx, pid, newName); err != nil {
		t.Fatalf("rename: %v", err)
	}

	loaded, err := ts.TeamLoad(ctx, id)
	if err != nil {
		t.Fatalf("team load: %v", err)
	}
	loaded.Version = created.Version
	if _, err := ts.TeamSave(ctx, id, loaded); err != nil {
		t.Fatalf("team save round-trip: %v", err)
	}

	var raw string
	if err := pool.QueryRow(ctx, `
		SELECT ttp.player_name FROM `+schema+`.tournament_team_players ttp
		JOIN `+schema+`.tournament_teams tt ON tt.id = ttp.team_id
		JOIN `+schema+`.tournaments t ON t.id = tt.tournament_id
		WHERE t.share_code = $1 AND ttp.player_id = $2::uuid`, id, pid).Scan(&raw); err != nil {
		t.Fatalf("read player_name: %v", err)
	}
	if raw != oldName {
		t.Fatalf("player_name tertimpa canonical: %q, want %q", raw, oldName)
	}
}
