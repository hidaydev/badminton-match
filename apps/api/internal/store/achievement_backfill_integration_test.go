package store

import (
	"context"
	"testing"

	"majadu-api/internal/domain"
)

// TestIntegrationRebuildBackfillsAchievements — rebuild menyegarkan medal.
//
// Regresi yang dikunci: backfill dulu HANYA dipanggil manual dari endpoint
// admin, sehingga medal turunan rating bisa usang. Terjadi di prod: peak
// rating para pemain naik setelah backfill terakhir, tapi medalnya tidak
// ikut lahir (rating_players di-update 2026-09-29, player_achievements
// 2026-09-13).
//
// Probe memakai medal:games (bukan medal:rating — medal itu dihapus bersama
// pensiunnya Glicko): nilai games dihapus dari player_achievements, lalu
// dipastikan rebuild menuliskannya kembali.
func TestIntegrationRebuildBackfillsAchievements(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	const prefix = "it-achbf"
	players := []domain.Player{
		{ID: "ab1", Name: "AB One", Gender: "M", Tier: 1},
		{ID: "ab2", Name: "AB Two", Gender: "M", Tier: 3},
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

	// Cukup banyak game agar medal "games" (ambang terendah 10) pasti lahir.
	// Satu event = satu game per pemain; rebuild mengisi games_played dari
	// jumlah delta, jadi event-nya harus nyata — bukan seed manual (rebuild
	// mereset games_played ke 0 lalu menghitung ulang).
	//
	// PENTING: pemain harus berada di sisi BERBEDA. Rebuild melewati event
	// yang salah satu sisinya tidak punya pemain non-absent (realA && realB),
	// dan gate itu tidak terlihat kalau kedua pemain ditaruh di team A.
	for i, date := range []string{
		"2026-09-20", "2026-09-21", "2026-09-22", "2026-09-23", "2026-09-24",
		"2026-09-25", "2026-09-26", "2026-09-27", "2026-09-28", "2026-09-29",
	} {
		insertRankTestEvent(t, st, ctx, schema,
			prefix+"-s"+string(rune('a'+i)), date, "session", 21, 0, 30, []playerSide{
				{id: "ab1", team: "A"}, {id: "ab2", team: "B"},
			})
	}

	countMedal := func() int {
		var n int
		if err := st.pool.QueryRow(ctx, `
			SELECT count(*) FROM `+schema+`.player_achievements
			WHERE player_id = $1::uuid AND achievement_key = 'medal:games'`, pid).Scan(&n); err != nil {
			t.Fatalf("count medal: %v", err)
		}
		return n
	}

	// Pastikan kondisi awal bersih supaya test benar-benar bermakna.
	if _, err := st.pool.Exec(ctx,
		`DELETE FROM `+schema+`.player_achievements WHERE player_id = $1::uuid AND achievement_key = 'medal:games'`, pid); err != nil {
		t.Fatalf("bersihkan medal: %v", err)
	}
	if countMedal() != 0 {
		t.Fatal("medal sudah ada sebelum rebuild — test tidak bermakna")
	}

	// Rebuild: ini yang dulu TIDAK menyegarkan achievement.
	if _, err := st.RebuildAll(ctx); err != nil {
		t.Fatalf("rebuild: %v", err)
	}
	if n := countMedal(); n != 1 {
		t.Fatalf("medal:games = %d, want 1 — rebuild tidak menyegarkan achievement", n)
	}

	// Paksa kondisi usang seperti prod: medal ada di DB, lalu DIHAPUS, lalu
	// rebuild lagi — backfill harus menuliskannya kembali.
	if _, err := st.pool.Exec(ctx,
		`DELETE FROM `+schema+`.player_achievements WHERE player_id = $1::uuid AND achievement_key = 'medal:games'`, pid); err != nil {
		t.Fatalf("hapus medal: %v", err)
	}
	if _, err := st.RebuildAll(ctx); err != nil {
		t.Fatalf("rebuild kedua: %v", err)
	}
	if n := countMedal(); n != 1 {
		t.Fatalf("medal:games = %d, want 1 — rebuild tidak menyegarkan achievement", n)
	}

	// Idempoten: rebuild lagi tidak menggandakan medal.
	if _, err := st.RebuildAll(ctx); err != nil {
		t.Fatalf("rebuild ketiga: %v", err)
	}
	if n := countMedal(); n != 1 {
		t.Fatalf("medal:games = %d setelah rebuild ulang, want tetap 1", n)
	}
}
