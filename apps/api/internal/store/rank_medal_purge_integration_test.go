package store

import (
	"context"
	"testing"

	"majadu-api/internal/domain"
)

// TestIntegrationPurgeStaleRankMedals — medal rank sepenuhnya turunan dari
// papan, jadi pemain yang keluar dari papan (mis. ambang entri minimum naik
// 3 → 5) harus kehilangan medalnya. Klausa upsert hanya memperbaiki nilai,
// tidak pernah menghapus baris — itulah yang ditutup rekonsiliasi ini.
func TestIntegrationPurgeStaleRankMedals(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	players := []domain.Player{
		{ID: "rp1", Name: "RP Keep", Gender: "M", Tier: 1},
		{ID: "rp2", Name: "RP Drop", Gender: "M", Tier: 1},
	}
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_achievements WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'RP %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'rp %'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'RP %'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	keep := resolveIDByAliasFuzzy(t, st, schema, "rp1")
	drop := resolveIDByAliasFuzzy(t, st, schema, "rp2")

	ins := func(pid, key, kind string, v int64) {
		t.Helper()
		if _, err := st.pool.Exec(ctx, `
			INSERT INTO `+schema+`.player_achievements (player_id, achievement_key, kind, earned_at, value)
			VALUES ($1::uuid, $2, $3, '2026-01-01', $4)
			ON CONFLICT (player_id, achievement_key) DO UPDATE SET value = EXCLUDED.value`,
			pid, key, kind, v); err != nil {
			t.Fatalf("insert %s: %v", key, err)
		}
	}
	has := func(pid, key string) bool {
		t.Helper()
		var n int
		if err := st.pool.QueryRow(ctx, `
			SELECT count(*) FROM `+schema+`.player_achievements
			WHERE player_id = $1::uuid AND achievement_key = $2`, pid, key).Scan(&n); err != nil {
			t.Fatalf("count %s: %v", key, err)
		}
		return n > 0
	}

	ins(keep, "medal:rank", "rank", 2)
	ins(keep, "medal:rank_streak", "rank", 6)
	ins(drop, "medal:rank", "rank", 4)
	ins(drop, "medal:rank_streak", "rank", 5)
	ins(drop, "medal:games", "volume", 10)

	// ok=false (timeline tak bisa dihitung / tanpa event) → jangan hapus apa pun.
	if err := st.purgeStaleRankMedals(ctx, rankMedalSets{}); err != nil {
		t.Fatalf("purge (ok=false): %v", err)
	}
	if !has(drop, "medal:rank") {
		t.Fatal("purge dengan ok=false menghapus medal — seharusnya dilewati")
	}

	// Hanya `keep` yang masih berhak: baris `drop` hilang, medal non-rank aman.
	if err := st.purgeStaleRankMedals(ctx, rankMedalSets{
		ok:      true,
		ranks:   []string{keep},
		streaks: []string{keep},
	}); err != nil {
		t.Fatalf("purge: %v", err)
	}
	if !has(keep, "medal:rank") || !has(keep, "medal:rank_streak") {
		t.Fatal("medal pemain yang masih berhak ikut terhapus")
	}
	if has(drop, "medal:rank") || has(drop, "medal:rank_streak") {
		t.Fatal("medal rank pemain yang tak lagi berhak tidak terhapus")
	}
	if !has(drop, "medal:games") {
		t.Fatal("medal non-rank ikut terhapus")
	}
}
