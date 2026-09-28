package store

import (
	"context"
	"testing"

	"majadu-api/internal/domain"
)

// ── Leaderboard eligibility & tie-break (paritas BWF §11/§14) ──────────────
//
// Eligibility: pemain tanpa hasil eligible (games_played = 0 — baris
// reset-to-default `RebuildAll` / forming) tidak diranking di view mana pun.
// Sebelum perbaikan, view active=false menampilkan mereka dengan rating
// baseline tier sehingga pemain 0-game duduk di papan peringkat.
//
// Tie-break: rating sama → yang lebih banyak main di atas. Kalau (rating,
// games) sama, posisi DIBAGI (1,2,2,4), bukan dipaksa unik.

const leaderboardITPrefix = "it-rating-lb"

// leaderboardITCleanup — bersihkan artefak test leaderboard. Dipanggil sebelum
// setup DAN di Cleanup: sisa run sebelumnya (test yang gagal di tengah) bikin
// rating_players/events menggantung dan test berikutnya tidak deterministik.
func leaderboardITCleanup(ctx context.Context, st *SessionStore, schema, prefix string) {
	like := prefix + "%"
	_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (
		SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE $1)`, like)
	_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE $1`, like)
	_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE $1`, like)
	_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (
		SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'ITLB %')`)
	_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.sessions SET status='draft' WHERE share_code LIKE $1`, like)
	_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE $1`, like)
}

// leaderboardITSetup — 4 pemain yang benar-benar main (ter-ingest), balik
// player_id (uuid) mereka sesuai urutan deklarasi.
func leaderboardITSetup(t *testing.T, st *SessionStore, ctx context.Context, suffix string) []string {
	t.Helper()
	players := []domain.Player{
		{ID: "itlb1", Name: "ITLB One", Gender: "M", Tier: 1},
		{ID: "itlb2", Name: "ITLB Two", Gender: "M", Tier: 2},
		{ID: "itlb3", Name: "ITLB Three", Gender: "M", Tier: 3},
		{ID: "itlb4", Name: "ITLB Four", Gender: "M", Tier: 4},
	}
	id := ratingCreateLockedSession(t, st, ctx, players, suffix)
	if _, err := st.IngestSession(ctx, id); err != nil {
		t.Fatalf("ingest: %v", err)
	}
	ids := make([]string, 0, len(players))
	for _, p := range players {
		ids = append(ids, resolveIDByAlias(t, st, lowerAlias(p.Name)))
	}
	return ids
}

// setPlayerRating — paksa (rating, games) langsung, supaya urutan leaderboard
// bisa diuji deterministik tanpa bergantung hasil ingest. wins/losses ikut
// diset karena ada CHECK (games_played = wins + losses).
func setPlayerRating(t *testing.T, st *SessionStore, ctx context.Context, schema, playerID string, rating float64, games int) {
	t.Helper()
	if _, err := st.pool.Exec(ctx, `
		UPDATE `+schema+`.rating_players
		SET rating = $2, games_played = $3, wins = $3, losses = 0, updated_at = now()
		WHERE player_id = $1::uuid`, playerID, rating, games); err != nil {
		t.Fatalf("set rating %s: %v", playerID, err)
	}
}

// maxRating — plafon rating yang ada, jadi basis nilai unik untuk test
// (di atas plafon ⇒ tidak ada pemain riil yang seri dengan pemain test).
// maxRating — rating tertinggi yang ada, dipakai test untuk menempatkan
// pemain di puncak papan.
//
// Dibatasi ke atas pada batas constraint `rating_players_rating_ck`
// (rating BETWEEN 1000 AND 2500) dikurangi ruang untuk penambahan pemanggil.
// DB integration test bisa berisi data prod (atau sisa test lain) yang sudah
// dekat batas atas; tanpa penjepit ini, test gagal karena constraint, bukan
// karena perilaku yang diuji.
func maxRating(t *testing.T, st *SessionStore, ctx context.Context, schema string) float64 {
	t.Helper()
	const ratingMax = 2500.0
	const headroom = 120.0 // ruang untuk base+i dan base+100
	var m float64
	if err := st.pool.QueryRow(ctx,
		`SELECT coalesce(max(rating), 0) FROM `+schema+`.rating_players`).Scan(&m); err != nil {
		t.Fatalf("max rating: %v", err)
	}
	if limit := ratingMax - headroom; m > limit {
		return limit
	}
	return m
}

// leaderboardRows — baris terurut (untuk cek urutan) + map by name.
func leaderboardRows(t *testing.T, st *SessionStore, ctx context.Context, active bool) ([]LeaderboardRow, map[string]LeaderboardRow) {
	t.Helper()
	_, rows, err := st.RatingLeaderboard(ctx, active, 20, 0)
	if err != nil {
		t.Fatalf("leaderboard(active=%v): %v", active, err)
	}
	byName := map[string]LeaderboardRow{}
	for _, r := range rows {
		byName[r.Name] = r
	}
	return rows, byName
}

// TestIntegrationLeaderboardExcludesZeroGamePlayers — pemain tanpa hasil
// eligible tidak muncul di view active MAUPUN all.
func TestIntegrationLeaderboardExcludesZeroGamePlayers(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	leaderboardITCleanup(ctx, st, schema, leaderboardITPrefix)
	t.Cleanup(func() { leaderboardITCleanup(ctx, st, schema, leaderboardITPrefix) })

	ids := leaderboardITSetup(t, st, ctx, "lb-elig")
	ghost := domain.Player{ID: "itlbghost", Name: "ITLB Ghost", Gender: "M", Tier: 1}
	if err := st.EnsurePlayersRegistered(ctx, []domain.Player{ghost}); err != nil {
		t.Fatalf("register ghost: %v", err)
	}
	ghostID := resolveIDByAlias(t, st, "itlb ghost")

	// Beri rating TERTINGGI yang ada tapi 0 game — meniru baris
	// reset-to-default `RebuildAll`. Kalau query-nya masih bocor, ghost
	// muncul di puncak, jadi kegagalannya jelas.
	base := maxRating(t, st, ctx, schema) + 10
	for i, pid := range ids {
		setPlayerRating(t, st, ctx, schema, pid, base+float64(i), 3)
	}
	if _, err := st.pool.Exec(ctx, `
		INSERT INTO `+schema+`.rating_players
			(player_id, rating, rd, peak_rating, games_played, wins, losses, last_played_at, updated_at)
		VALUES ($1::uuid, $2, 220, $2, 0, 0, 0, NULL, now())
		ON CONFLICT (player_id) DO UPDATE SET
			rating = $2, games_played = 0, wins = 0, losses = 0, last_played_at = NULL`,
		ghostID, base+100); err != nil {
		t.Fatalf("insert ghost rating row: %v", err)
	}

	// Barisnya harus benar-benar ada dengan 0 game — kalau tidak, "absen" di
	// leaderboard tidak membuktikan apa pun.
	var games int
	if err := st.pool.QueryRow(ctx,
		`SELECT games_played FROM `+schema+`.rating_players WHERE player_id = $1::uuid`,
		ghostID).Scan(&games); err != nil {
		t.Fatalf("baris rating ghost hilang: %v", err)
	}
	if games != 0 {
		t.Fatalf("ghost games_played = %d, want 0", games)
	}

	for _, active := range []bool{false, true} {
		after := "pemain 0-game ikut diranking"
		_, byName := leaderboardRows(t, st, ctx, active)
		if row, ok := byName["ITLB Ghost"]; ok {
			t.Fatalf("active=%v: %s (rank %d, rating %.2f)", active, after, row.Rank, row.Rating)
		}
		// Keempat pemain nyata harus mengisi persis rank 1..4: rating mereka
		// yang tertinggi di DB. Ghost punya rating PALING tinggi tapi 0 game —
		// kalau query bocor, ghost menempati rank 1 dan himpunan ini rusak.
		got := map[int]string{}
		for _, name := range []string{"ITLB One", "ITLB Two", "ITLB Three", "ITLB Four"} {
			row, ok := byName[name]
			if !ok {
				t.Fatalf("active=%v: %s hilang dari leaderboard", active, name)
			}
			got[row.Rank] = name
		}
		for r := 1; r <= 4; r++ {
			if got[r] == "" {
				t.Fatalf("active=%v: rank %d bukan pemain test (dapat %v) — pemain 0-game bocor ke leaderboard?",
					active, r, got)
			}
		}
	}
}

// TestIntegrationLeaderboardTieBreak — rating sama → lebih banyak main di atas;
// (rating, games) sama → posisi dibagi, nomor berikutnya melompat.
func TestIntegrationLeaderboardTieBreak(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	leaderboardITCleanup(ctx, st, schema, leaderboardITPrefix)
	t.Cleanup(func() { leaderboardITCleanup(ctx, st, schema, leaderboardITPrefix) })

	ids := leaderboardITSetup(t, st, ctx, "lb-tie")

	// Semua di atas rating yang ada → nomor posisinya deterministik.
	base := maxRating(t, st, ctx, schema) + 10
	setPlayerRating(t, st, ctx, schema, ids[0], base, 5)     // One   — seri dengan Two
	setPlayerRating(t, st, ctx, schema, ids[1], base, 5)     // Two   — seri dengan One
	setPlayerRating(t, st, ctx, schema, ids[2], base, 2)     // Three — rating sama, main lebih sedikit
	setPlayerRating(t, st, ctx, schema, ids[3], base-0.1, 9) // Four  — rating lebih rendah

	rows, byName := leaderboardRows(t, st, ctx, false)

	one, ok1 := byName["ITLB One"]
	two, ok2 := byName["ITLB Two"]
	three, ok3 := byName["ITLB Three"]
	four, ok4 := byName["ITLB Four"]
	if !ok1 || !ok2 || !ok3 || !ok4 {
		t.Fatalf("pemain test tidak lengkap di leaderboard: %v %v %v %v", ok1, ok2, ok3, ok4)
	}

	if one.Rank != 1 || two.Rank != 1 {
		t.Fatalf("posisi seri: One rank %d, Two rank %d — want 1 & 1 (rating+games identik)",
			one.Rank, two.Rank)
	}
	if three.Rank != 3 {
		t.Fatalf("Three rank %d, want 3 — rating sama tapi main lebih sedikit harus di bawah, "+
			"dan nomor setelah seri melompat (1,1,3)", three.Rank)
	}
	if four.Rank != 4 {
		t.Fatalf("Four rank %d, want 4 — rating lebih rendah harus di bawah Three", four.Rank)
	}

	// Urutan baris nyata harus konsisten dengan rank.
	pos := map[string]int{}
	for i, r := range rows {
		pos[r.Name] = i
	}
	if pos["ITLB One"] >= pos["ITLB Three"] || pos["ITLB Two"] >= pos["ITLB Three"] ||
		pos["ITLB Three"] >= pos["ITLB Four"] {
		t.Fatalf("urutan baris salah: One=%d Two=%d Three=%d Four=%d",
			pos["ITLB One"], pos["ITLB Two"], pos["ITLB Three"], pos["ITLB Four"])
	}
}
