package store

import (
	"context"
	"testing"

	"majadu-api/internal/domain"
)

// TestIntegrationAutoIngestTournament — turnamen yang SEMUA matchnya berskor
// harus ter-ingest otomatis (finalisasi + ingest), dan yang belum lengkap
// TIDAK boleh disentuh.
//
// Regression: sebelum perbaikan, ticker hanya menyapu tabel `sessions`,
// sehingga turnamen tidak pernah masuk rating sama sekali — turnamen klasik
// 23 Mei 2026 bahkan tidak punya baris di rating_sources.
func TestIntegrationAutoIngestTournament(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	const prefix = "it-rating-tv"
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (
			SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE $1)`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE $1`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE $1`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (
			SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'ITT %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.tournament_pair_players WHERE pair_id IN (
			SELECT id FROM `+schema+`.tournament_pairs WHERE tournament_id IN (
				SELECT id FROM `+schema+`.tournaments WHERE share_code LIKE $1))`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.tournament_pairs WHERE tournament_id IN (
			SELECT id FROM `+schema+`.tournaments WHERE share_code LIKE $1)`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.tournament_matches WHERE tournament_id IN (
			SELECT id FROM `+schema+`.tournaments WHERE share_code LIKE $1)`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.tournaments WHERE share_code LIKE $1`, prefix+"%")
	}
	cleanup()
	t.Cleanup(cleanup)

	// ── 4 pemain (2 pasangan) ──
	players := []domain.Player{
		{ID: "itt1", Name: "ITT One", Gender: "M", Tier: 2},
		{ID: "itt2", Name: "ITT Two", Gender: "M", Tier: 3},
		{ID: "itt3", Name: "ITT Three", Gender: "M", Tier: 4},
		{ID: "itt4", Name: "ITT Four", Gender: "M", Tier: 5},
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	pids := make([]string, 0, len(players))
	for _, p := range players {
		pids = append(pids, resolveIDByAlias(t, st, lowerAlias(p.Name)))
	}

	// Turnamen test harus bertanggal SETELAH event terakhir di DB, kalau tidak
	// ingest menolak dengan ErrOutOfOrder (invariant kronologis). DB test bisa
	// berisi data prod, jadi tanggal dihitung relatif ke max(date) yang ada.
	var eventDate string
	if err := st.pool.QueryRow(ctx, `
		SELECT (COALESCE(max(date), CURRENT_DATE) + INTERVAL '1 day')::date::text
		FROM `+schema+`.rating_events`).Scan(&eventDate); err != nil {
		t.Fatalf("hitung tanggal turnamen test: %v", err)
	}

	_, shareComplete := createTestClassicTournament(t, st, ctx, schema, prefix+"-ok", eventDate, true, pids)
	_, shareIncomplete := createTestClassicTournament(t, st, ctx, schema, prefix+"-partial", eventDate, false, pids)
	// Turnamen TANPA match sama sekali: dulu lolos gate (NOT EXISTS pada
	// himpunan kosong = TRUE) -> ter-finalisasi tanpa event, dan karena
	// rating_sources terisi, tidak pernah dicoba lagi.
	_, shareEmpty := createTestClassicTournament(t, st, ctx, schema, prefix+"-nomatch", eventDate, true, pids, true)

	n, err := st.AutoIngestTournaments(ctx)
	if err != nil {
		t.Fatalf("auto-ingest turnamen: %v", err)
	}
	if n < 1 {
		t.Fatalf("turnamen ter-ingest = %d, want >=1 (turnamen lengkap harus masuk)", n)
	}

	// Turnamen lengkap: harus punya events
	var evComplete int
	if err := st.pool.QueryRow(ctx,
		`SELECT count(*) FROM `+schema+`.rating_events WHERE source_id = $1`, shareComplete).Scan(&evComplete); err != nil {
		t.Fatalf("hitung event turnamen lengkap: %v", err)
	}
	if evComplete == 0 {
		t.Fatalf("turnamen lengkap %s tidak menghasilkan event", shareComplete)
	}
	// dan kind-nya benar
	var kind string
	if err := st.pool.QueryRow(ctx,
		`SELECT DISTINCT kind FROM `+schema+`.rating_events WHERE source_id = $1`, shareComplete).Scan(&kind); err != nil {
		t.Fatalf("kind: %v", err)
	}
	if kind != "tournament_classic" {
		t.Fatalf("kind = %q, want tournament_classic", kind)
	}
	// dan ter-finalisasi
	var fin bool
	if err := st.pool.QueryRow(ctx,
		`SELECT finalized FROM `+schema+`.rating_sources WHERE source_id = $1`, shareComplete).Scan(&fin); err != nil {
		t.Fatalf("finalized: %v", err)
	}
	if !fin {
		t.Fatalf("turnamen %s tidak difinalisasi", shareComplete)
	}

	// Turnamen belum lengkap: TIDAK boleh ter-ingest
	var evIncomplete int
	if err := st.pool.QueryRow(ctx,
		`SELECT count(*) FROM `+schema+`.rating_events WHERE source_id = $1`, shareIncomplete).Scan(&evIncomplete); err != nil {
		t.Fatalf("hitung event turnamen belum lengkap: %v", err)
	}
	if evIncomplete != 0 {
		t.Fatalf("turnamen belum lengkap %s ikut ter-ingest (%d event) — match kosong harus memblokir",
			shareIncomplete, evIncomplete)
	}

	// Turnamen tanpa match: TIDAK boleh ter-finalisasi/ter-ingest
	var evEmpty int
	if err := st.pool.QueryRow(ctx,
		`SELECT count(*) FROM `+schema+`.rating_events WHERE source_id = $1`, shareEmpty).Scan(&evEmpty); err != nil {
		t.Fatalf("hitung event turnamen tanpa match: %v", err)
	}
	if evEmpty != 0 {
		t.Fatalf("turnamen tanpa match %s menghasilkan %d event", shareEmpty, evEmpty)
	}
	var srcEmpty int
	if err := st.pool.QueryRow(ctx,
		`SELECT count(*) FROM `+schema+`.rating_sources WHERE source_id = $1 AND fingerprint != ''`, shareEmpty).Scan(&srcEmpty); err != nil {
		t.Fatalf("hitung source turnamen tanpa match: %v", err)
	}
	if srcEmpty != 0 {
		t.Fatalf("turnamen tanpa match %s tercatat ter-ingest (fingerprint terisi) — tidak akan pernah dicoba lagi", shareEmpty)
	}

	// Idempotent: jalan kedua tidak meng-ingest ulang
	n2, err := st.AutoIngestTournaments(ctx)
	if err != nil {
		t.Fatalf("auto-ingest kedua: %v", err)
	}
	if n2 != 0 {
		t.Fatalf("auto-ingest kedua = %d, want 0 (idempotent)", n2)
	}

	// CountUnscoredTournamentMatches: turnamen lengkap = 0 (dipakai utk log)
	if got, err := st.CountUnscoredTournamentMatches(ctx, shareComplete); err != nil || got != 0 {
		t.Fatalf("unscored turnamen lengkap = %d err=%v, want 0", got, err)
	}
	if got, err := st.CountUnscoredTournamentMatches(ctx, shareIncomplete); err != nil || got == 0 {
		t.Fatalf("unscored turnamen belum lengkap = %d err=%v, want >0", got, err)
	}
}

// createTestClassicTournament — bikin turnamen classic 4 pasangan (2 pasangan
// lawan 2 pasangan, 1 match) utk menguji gate "semua match berskor".
// complete=false → skor satu match dikosongkan.
// noMatch=true → turnamen tanpa match sama sekali.
//
// eventDate: WAJIB diisi pemanggil. Ingest menegakkan invariant "kronologis"
// (batch harus lebih baru dari event terakhir di DB), dan DB test biasanya
// berisi data prod — jadi tanggal CURRENT_DATE bisa ditolak ErrOutOfOrder.
func createTestClassicTournament(t *testing.T, st *SessionStore, ctx context.Context, schema, shareCode, eventDate string, complete bool, pids []string, noMatch ...bool) (string, string) {
	t.Helper()

	var tourID string
	if err := st.pool.QueryRow(ctx, `
		INSERT INTO `+schema+`.tournaments (share_code, name, event_date, format, version)
		VALUES ($1, $2, $3::date, 'classic', 1)
		RETURNING id::text`, shareCode, "ITT "+shareCode, eventDate).Scan(&tourID); err != nil {
		t.Fatalf("insert tournament: %v", err)
	}

	skipMatch := len(noMatch) > 0 && noMatch[0]
	if skipMatch {
		return tourID, shareCode
	}

	// 2 pasangan × 2 pemain
	pairIDs := make([]string, 0, 2)
	for i := 0; i < 2; i++ {
		var pid string
		if err := st.pool.QueryRow(ctx, `
			INSERT INTO `+schema+`.tournament_pairs (tournament_id, pair_name, seed)
			VALUES ($1::uuid, $2, $3) RETURNING id::text`, tourID, "ITT Pair", i+1).Scan(&pid); err != nil {
			t.Fatalf("insert pair: %v", err)
		}
		pairIDs = append(pairIDs, pid)
		for j := 0; j < 2; j++ {
			if _, err := st.pool.Exec(ctx, `
				INSERT INTO `+schema+`.tournament_pair_players (pair_id, player_id)
				VALUES ($1::uuid, $2::uuid)`, pid, pids[i*2+j]); err != nil {
				t.Fatalf("insert pair player: %v", err)
			}
		}
	}

	// 1 match: lengkap → ada skor; belum lengkap → skor NULL
	var sa, sb any
	if complete {
		sa, sb = 21, 15
	}
	if _, err := st.pool.Exec(ctx, `
		INSERT INTO `+schema+`.tournament_matches
			(tournament_id, phase, pair_a_id, pair_b_id, score_a, score_b, match_order, match_key)
		VALUES ($1::uuid, 'final', $2::uuid, $3::uuid, $4, $5, 1, $6)`,
		tourID, pairIDs[0], pairIDs[1], sa, sb, shareCode+"-m1"); err != nil {
		t.Fatalf("insert match: %v", err)
	}
	return tourID, shareCode
}
