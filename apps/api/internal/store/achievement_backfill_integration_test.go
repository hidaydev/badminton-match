package store

import (
	"context"
	"testing"

	"majadu-api/internal/domain"
)

// TestIntegrationRebuildBackfillsAchievements — rebuild menyegarkan medal.
//
// Regresi yang dikunci: backfill dulu HANYA dipanggil manual dari endpoint
// admin, sehingga medal turunan rating bisa usang. Terjadi di prod: Revfath
// (peak 2050) & Raihan (2052) punya peak di atas ambang 2000 tapi tanpa
// medal, karena replay terakhir menaikkan peak_rating setelah backfill
// terakhir dijalankan (2026-09-13 vs 2026-09-29).
//
// Test ini menulis nilai peak langsung ke rating_players melewati ambang,
// menghapus medalnya, lalu memastikan rebuild menuliskannya kembali.
func TestIntegrationRebuildBackfillsAchievements(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	const prefix = "it-achbf"
	players := []domain.Player{
		{ID: "ab1", Name: "AB One", Gender: "M", Tier: 1},
		{ID: "ab2", Name: "AB Two", Gender: "M", Tier: 3},
		{ID: "ab3", Name: "AB Three", Gender: "M", Tier: 3},
		{ID: "ab4", Name: "AB Four", Gender: "M", Tier: 1},
	}
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_achievements WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'AB %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'AB %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'ab %'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'AB %'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	pid := resolveIDByAliasFuzzy(t, st, schema, "ab2")

	// Satu sesi supaya ada event (rebuild butuh pemetaan) + rating_players.
	insertRankTestEvent(t, st, ctx, schema, prefix+"-s", "2026-09-27", "session", 21, 0, 30, []playerSide{
		{id: "ab1", team: "A"}, {id: "ab2", team: "A"},
		{id: "ab3", team: "B"}, {id: "ab4", team: "B"},
	})
	// AB Two diberi tier tinggi supaya jalur tier-nya jelas; nilai peak
	// sengaja dinaikkan melewati ambang medali (2000).
	if _, err := st.pool.Exec(ctx,
		`UPDATE `+schema+`.players SET tier = 'A' WHERE id = $1::uuid`, pid); err != nil {
		t.Fatalf("set tier: %v", err)
	}

	// Medal belum ada.
	countMedal := func() int {
		var n int
		if err := st.pool.QueryRow(ctx, `
			SELECT count(*) FROM `+schema+`.player_achievements
			WHERE player_id = $1::uuid AND achievement_key = 'medal:rating'`, pid).Scan(&n); err != nil {
			t.Fatalf("count medal: %v", err)
		}
		return n
	}
	if countMedal() != 0 {
		t.Fatal("medal sudah ada sebelum rebuild — test tidak bermakna")
	}

	// Rebuild: ini yang dulu TIDAK menyegarkan achievement.
	if _, err := st.RebuildAll(ctx); err != nil {
		t.Fatalf("rebuild: %v", err)
	}

	// Peak ditulis rebuild dari data event (placeholder/nilai nyata). Yang
	// dikunci di sini adalah JALUR pemanggilan backfill-nya: kalau rebuild
	// tidak memanggil backfill, medal tidak akan pernah muncul pada kondisi
	// mana pun.
	var peak float64
	if err := st.pool.QueryRow(ctx,
		`SELECT peak_rating FROM `+schema+`.rating_players WHERE player_id = $1::uuid`, pid).Scan(&peak); err != nil {
		t.Fatalf("baca peak: %v", err)
	}
	t.Logf("peak setelah rebuild: %.1f", peak)

	// Paksa kondisi seperti prod: peak di atas ambang, lalu rebuild lagi —
	// backfill harus menulis medal-nya.
	if _, err := st.pool.Exec(ctx,
		`UPDATE `+schema+`.rating_players SET peak_rating = 2050 WHERE player_id = $1::uuid`, pid); err != nil {
		t.Fatalf("set peak: %v", err)
	}
	if _, err := st.RebuildAll(ctx); err != nil {
		t.Fatalf("rebuild kedua: %v", err)
	}
	if n := countMedal(); n != 1 {
		t.Fatalf("medal:rating = %d, want 1 — rebuild tidak menyegarkan achievement", n)
	}

	// Idempoten: rebuild lagi tidak menggandakan medal.
	if _, err := st.RebuildAll(ctx); err != nil {
		t.Fatalf("rebuild ketiga: %v", err)
	}
	if n := countMedal(); n != 1 {
		t.Fatalf("medal:rating = %d setelah rebuild ulang, want tetap 1", n)
	}
}
