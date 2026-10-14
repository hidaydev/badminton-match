package store

import (
	"context"
	"testing"

	"majadu-api/internal/domain"
)

// TestIntegrationRankMinSessions — ambang entri minimum papan publik.
//
// Pemain yang entri di window-nya di bawah ambang hilang dari papan DAN dari
// jalur satu-pemain (found=false), karena keduanya memakai definisi papan yang
// sama. Handler memakai keduanya untuk menampilkan "butuh minimal N sesi".
func TestIntegrationRankMinSessions(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	const prefix = "it-rankin"
	players := []domain.Player{
		{ID: "rmn1", Name: "RMN One", Gender: "M", Tier: 5},
		{ID: "rmn2", Name: "RMN Two", Gender: "M", Tier: 5},
	}
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rank_snapshots WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'RMN %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'RMN %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'rmn %'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'RMN %'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	p1 := resolveIDByAliasFuzzy(t, st, schema, "rmn1")

	setMin := func(n int) {
		t.Helper()
		if _, err := st.pool.Exec(ctx, `
			INSERT INTO `+schema+`.rating_config (key, value)
			VALUES ('rank_min_sessions', to_jsonb($1::int))
			ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value`, n); err != nil {
			t.Fatalf("set min_sessions=%d: %v", n, err)
		}
	}
	// Kembalikan pin env (0) apa pun hasil test ini.
	t.Cleanup(func() { setMin(0) })

	// Dua sesi → dua entri untuk pemain uji.
	base := dateAfterAllEvents(t, st, schema)
	insertRankTestEvent(t, st, ctx, schema, prefix+"-s0", base, "session", 21, 10, 21, []playerSide{
		{id: "rmn1", team: "A"}, {id: "rmn2", team: "B"},
	})
	insertRankTestEvent(t, st, ctx, schema, prefix+"-s1", dateMinusDays(t, base, 7), "session", 21, 10, 21, []playerSide{
		{id: "rmn1", team: "A"}, {id: "rmn2", team: "B"},
	})

	// want = 0 → pemain harus TIDAK ada di papan; want > 0 → entri yang terlihat.
	assertEntries := func(want int) {
		t.Helper()
		board, err := st.RankPointsBoard(ctx, "", 0)
		if err != nil {
			t.Fatalf("board: %v", err)
		}
		got := 0
		for _, r := range board.Rows {
			if r.PlayerID == p1 {
				got = r.EntriesAvailable
			}
		}
		if want == 0 && got != 0 {
			t.Fatalf("ambang %d: entri=%d, want pemain tidak tampil", board.MinSessions, got)
		}
		if want > 0 && got != want {
			t.Fatalf("ambang %d: entri=%d, want %d", board.MinSessions, got, want)
		}
	}

	// Ambang 2 → dua entri lolos.
	setMin(2)
	assertEntries(2)
	if _, found, err := st.RankPointsForPlayer(ctx, p1, ""); err != nil || !found {
		t.Fatalf("ambang 2: jalur satu-pemain found=%v err=%v, want true", found, err)
	}

	// Ambang 3 → dua entri tidak cukup: hilang dari papan DAN jalur satu-pemain.
	setMin(3)
	assertEntries(0)
	if _, found, err := st.RankPointsForPlayer(ctx, p1, ""); err != nil || found {
		t.Fatalf("ambang 3: jalur satu-pemain found=%v err=%v, want false", found, err)
	}
	if n, err := st.RankMinSessions(ctx); err != nil || n != 3 {
		t.Fatalf("RankMinSessions = %d,%v want 3", n, err)
	}
}
