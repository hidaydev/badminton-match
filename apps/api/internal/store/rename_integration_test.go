package store

import (
	"context"
	"fmt"
	"testing"
	"time"

	"majadu-api/internal/domain"
)

// TestIntegrationRenamePropagation — rename pemain harus:
//   - meng-update session_players.source_name untuk sumber yang BELUM ter-ingest;
//   - TIDAK meng-update sumber yang sudah ter-ingest (fingerprint non-kosong),
//     agar re-ingest tidak kena ErrSourceChanged.
//
// Butuh MAJADU_TEST_DATABASE_URL (lihat ratingTestEnv).
func TestIntegrationRenamePropagation(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()
	pool := st.pool
	ps := NewPlayerStore(pool, schema)

	players := []domain.Player{
		{ID: "rn1", Name: "RenameProp One", Gender: "M", Tier: 3},
		{ID: "rn2", Name: "RenameProp Two", Gender: "M", Tier: 3},
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	defer func() {
		for _, n := range []string{"renameprop one", "renameprop two"} {
			pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name = $1`, n)
		}
	}()

	playerID := func(name string) string {
		t.Helper()
		var pid string
		if err := pool.QueryRow(ctx,
			`SELECT player_id::text FROM `+schema+`.player_aliases WHERE alias_name = $1`,
			domain.NormalizePlayerName(name)).Scan(&pid); err != nil {
			t.Fatalf("resolve %q: %v", name, err)
		}
		return pid
	}

	id := "it-rename-" + fmt.Sprintf("%d", time.Now().UnixNano())
	defer pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code = $1`, id)
	defer pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id = $1`, id)

	snap := &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "Rename IT", Date: "2026-08-20", Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: len(players),
			CourtNames:  []string{"C1"},
		},
		Players:     players,
		FixMatches:  []domain.FixMatch{},
		Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"rn1", "rn2"}, TeamB: [2]string{"rn1", "rn2"}}},
		PlayedGames: []string{},
		GameScores:  map[string]domain.GameScore{},
	}
	if _, err := st.Save(ctx, id, snap); err != nil {
		t.Fatalf("save session: %v", err)
	}

	pid1 := playerID("RenameProp One")

	// (1) Belum ter-ingest → source_name ikut berubah.
	if err := ps.RenamePlayer(ctx, pid1, "RenameProp One Baru"); err != nil {
		t.Fatalf("rename pid1: %v", err)
	}
	var src1 string
	if err := pool.QueryRow(ctx, `
		SELECT sp.source_name
		FROM `+schema+`.session_players sp
		JOIN `+schema+`.sessions s ON s.id = sp.session_id
		WHERE s.share_code = $1 AND sp.player_id = $2::uuid`, id, pid1).Scan(&src1); err != nil {
		t.Fatalf("read source_name pid1: %v", err)
	}
	if src1 != "RenameProp One Baru" {
		t.Fatalf("un-ingested source_name = %q, want %q", src1, "RenameProp One Baru")
	}

	// (2) Tandai sumber sudah ter-ingest (fingerprint non-kosong) → rename
	// pemain kedua TIDAK boleh mengubah source_name.
	if _, err := pool.Exec(ctx, `
		INSERT INTO `+schema+`.rating_sources
			(source_id, source_kind, fingerprint, finalized, last_ingested_seq, ingested_at)
		VALUES ($1, 'session', 'fp-test', true, 0, now())
		ON CONFLICT (source_id) DO UPDATE SET fingerprint = 'fp-test'`, id); err != nil {
		t.Fatalf("seed rating_sources: %v", err)
	}
	pid2 := playerID("RenameProp Two")
	if err := ps.RenamePlayer(ctx, pid2, "RenameProp Two Baru"); err != nil {
		t.Fatalf("rename pid2: %v", err)
	}
	var src2 string
	if err := pool.QueryRow(ctx, `
		SELECT sp.source_name
		FROM `+schema+`.session_players sp
		JOIN `+schema+`.sessions s ON s.id = sp.session_id
		WHERE s.share_code = $1 AND sp.player_id = $2::uuid`, id, pid2).Scan(&src2); err != nil {
		t.Fatalf("read source_name pid2: %v", err)
	}
	if src2 != "RenameProp Two" {
		t.Fatalf("ingested source_name = %q, want unchanged %q", src2, "RenameProp Two")
	}

	// Nama BARU harus resolvable sebagai alias (kalau tidak, publish/rating
	// sesi berikutnya gagal).
	for _, want := range []string{"renameprop one baru", "renameprop two baru"} {
		var n int
		if err := pool.QueryRow(ctx,
			`SELECT count(*) FROM `+schema+`.player_aliases WHERE alias_name = $1`, want).Scan(&n); err != nil {
			t.Fatalf("count alias %q: %v", want, err)
		}
		if n == 0 {
			t.Fatalf("alias baru %q tidak terdaftar", want)
		}
	}
}
