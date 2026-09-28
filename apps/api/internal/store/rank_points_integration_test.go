package store

import (
	"context"
	"fmt"
	"testing"
	"time"

	"majadu-api/internal/domain"
)

// TestIntegrationRankPointsBoard — papan poin: window 12 minggu, 10 entri
// terbaik, pengali kekuatan lawan, dan penanda bukti tipis.
//
// Poin dihitung saat baca dari rating_events + rating_deltas, jadi test ini
// membangun event sendiri lalu memeriksa agregasinya.
func TestIntegrationRankPointsBoard(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	const prefix = "it-rankpts"
	players := []domain.Player{
		{ID: "rp1", Name: "RP One", Gender: "M", Tier: 5}, // kuat
		{ID: "rp2", Name: "RP Two", Gender: "M", Tier: 5},
		{ID: "rp3", Name: "RP Three", Gender: "M", Tier: 1}, // lemah
		{ID: "rp4", Name: "RP Four", Gender: "M", Tier: 1},
		{ID: "rp5", Name: "RP Five", Gender: "M", Tier: 1},
		{ID: "rp6", Name: "RP Six", Gender: "M", Tier: 1},
	}
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE 'it-rankpts%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE 'it-rankpts%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE 'it-rankpts%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.scheduled_games WHERE session_id IN (SELECT id FROM `+schema+`.sessions WHERE share_code LIKE 'it-rankpts%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE 'it-rankpts%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'RP %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'rp %'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'RP %'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}

	// ── Siapkan rating_players manual: RP One kuat, sisanya lemah. ──
	// Papan butuh rating untuk pengali kekuatan lawan.
	ratingOf := map[string]float64{"rp1": 2000, "rp2": 2000, "rp3": 1200, "rp4": 1200, "rp5": 1200, "rp6": 1200}
	for id, r := range ratingOf {
		pid := resolveIDByAliasFuzzy(t, st, schema, id)
		if _, err := st.pool.Exec(ctx, `
			INSERT INTO `+schema+`.rating_players (player_id, rating, rd, peak_rating, games_played, wins, losses)
			VALUES ($1::uuid, $2, 100, $2, 1, 1, 0)
			ON CONFLICT (player_id) DO UPDATE SET rating = EXCLUDED.rating, games_played = 1, rd = 100, peak_rating = EXCLUDED.peak_rating`,
			pid, r); err != nil {
			t.Fatalf("seed rating %s: %v", id, err)
		}
	}

	// ── Event: RP One menang telak melawan pemain lemah, 12 sesi terpisah.
	// Diharapkan: hanya 10 entri terbaik dihitung (best_n=10).
	baseDate := "2026-09-27"
	for i := 0; i < 12; i++ {
		src := prefix + "-s" + pad2(i)
		date := dateMinusDays(t, baseDate, i*3) // semua dalam 12 minggu
		// menang 21-0 (telak) — skor sama tiap sesi supaya poin entri identik
		insertRankTestEvent(t, st, ctx, schema, src, date, "session",
			21, 0, 21, []playerSide{
				{id: "rp1", team: "A"}, {id: "rp2", team: "A"},
				{id: "rp3", team: "B"}, {id: "rp4", team: "B"},
			})
	}
	// Satu sesi di LUAR window (13 minggu lalu) — harus diabaikan window.
	// Pemain: RP One + RP Two melawan RP Five + RP Six.
	insertRankTestEvent(t, st, ctx, schema, prefix+"-old", dateMinusDays(t, baseDate, 13*7), "session",
		21, 0, 21, []playerSide{
			{id: "rp1", team: "A"}, {id: "rp2", team: "A"},
			{id: "rp5", team: "B"}, {id: "rp6", team: "B"},
		})

	board, err := st.RankPointsBoard(ctx, baseDate, 5000)
	if err != nil {
		t.Fatalf("board: %v", err)
	}
	if board.WindowWeeks != 12 || board.BestN != 10 {
		t.Fatalf("window=%d best_n=%d, want 12/10", board.WindowWeeks, board.BestN)
	}

	var rpOne *RankPointRow
	for i := range board.Rows {
		if board.Rows[i].Name == "RP One" {
			rpOne = &board.Rows[i]
		}
	}
	if rpOne == nil {
		t.Fatalf("RP One tidak ada di papan (rows=%d)", len(board.Rows))
	}
	// 13 entri ada di DB, tapi hanya 10 (best_n) yang dihitung.
	if rpOne.CountedEntries != 10 {
		t.Fatalf("RP One counted_entries=%d, want 10 (best_n)", rpOne.CountedEntries)
	}
	if len(rpOne.Breakdown) != 10 {
		t.Fatalf("RP One breakdown=%d entri, want 10", len(rpOne.Breakdown))
	}
	// Entri di luar window tidak boleh muncul.
	for _, e := range rpOne.Breakdown {
		if e.SourceID == prefix+"-old" {
			t.Fatal("entri di luar window (13 minggu) ikut dihitung")
		}
	}

	// RP Six hanya bermain di sesi di LUAR window (13 minggu lalu), jadi ia
	// tidak boleh muncul di papan sama sekali — bukti filter window bekerja.
	for i := range board.Rows {
		if board.Rows[i].Name == "RP Six" {
			t.Fatalf("RP Six muncul di papan dengan %d entri — sesi di luar window (13 minggu) ikut dihitung",
				board.Rows[i].EntriesAvailable)
		}
	}

	// Bukti tipis: pemain dengan entri < rank_thin_evidence_n (3) ditandai.
	// RP Two bermain di semua 12 sesi (10 dihitung) → tidak tipis.
	var rpTwo *RankPointRow
	for i := range board.Rows {
		if board.Rows[i].Name == "RP Two" {
			rpTwo = &board.Rows[i]
		}
	}
	if rpTwo == nil {
		t.Fatal("RP Two tidak ada di papan")
	}
	if rpTwo.ThinEvidence {
		t.Fatalf("RP Two entri=%d tapi thin_evidence=true (ambang 3)", rpTwo.EntriesAvailable)
	}

	// ── Pengali kekuatan lawan ──
	// RP One (rating 2000) bermain melawan RP Three/RP Four (rating 1200).
	// Nilai game mentah tiap sesi = 1 game × 250 (menang telak, margin 21 =
	// target 21 → nilai 250). Tanpa pengali, poin entri = 250.
	// Dengan pengali (rata-rata lawan / rata-rata populasi, dijepit), poin
	// harus BERBEDA dari 250 — dan arahnya sesuai rumus.
	popAvg, err := st.popAverageRating(ctx)
	if err != nil {
		t.Fatalf("populasi: %v", err)
	}
	if popAvg <= 0 {
		t.Fatal("rata-rata populasi 0 — pengali tidak akan pernah diuji")
	}
	wantMult := 1200 / popAvg
	if wantMult < 0.5 {
		wantMult = 0.5
	}
	if wantMult > 1.5 {
		wantMult = 1.5
	}
	wantEntryPoints := 250 * wantMult
	got := rpOne.Breakdown[0].Points
	if diff := got - wantEntryPoints; diff > 0.5 || diff < -0.5 {
		t.Fatalf("poin entri terbaik RP One = %.4f, want %.4f (250 × %.4f) — pengali kekuatan lawan tidak diterapkan dengan benar",
			got, wantEntryPoints, wantMult)
	}
	if got == 250 {
		t.Fatal("poin entri tepat 250 (nilai mentah) — pengali kekuatan lawan dilewati")
	}
}

// playerSide — pemain + tim untuk menyusun event uji.
type playerSide struct {
	id   string
	team string
}

// resolveIDByAliasFuzzy — cari player_id dari kode pemain uji (rp1, rp2, ...)
// lewat daftar alias yang dibuat EnsurePlayersRegistered ("RP One" → "rp one").
func resolveIDByAliasFuzzy(t *testing.T, st *SessionStore, schema, code string) string {
	t.Helper()
	names := map[string]string{
		"rp1": "RP One", "rp2": "RP Two", "rp3": "RP Three",
		"rp4": "RP Four", "rp5": "RP Five", "rp6": "RP Six",
	}
	name, ok := names[code]
	if !ok {
		t.Fatalf("kode pemain %q tidak dikenal", code)
	}
	return resolveIDByAlias(t, st, lowerAlias(name))
}

// pad2 — nomor jadi 2 digit (s0 → s00) supaya nama source terurut stabil.
func pad2(n int) string {
	if n < 10 {
		return "0" + string(rune('0'+n))
	}
	return string(rune('0'+n/10)) + string(rune('0'+n%10))
}

// dateMinusDays — kurangi tanggal (yyyy-mm-dd) dengan n hari.
func dateMinusDays(t *testing.T, date string, days int) string {
	t.Helper()
	d, err := parseDate(date)
	if err != nil {
		t.Fatalf("parse %q: %v", date, err)
	}
	return d.AddDate(0, 0, -days).Format("2006-01-02")
}

// parseDate — parse yyyy-mm-dd.
func parseDate(s string) (time.Time, error) {
	return time.Parse("2006-01-02", s)
}

// insertRankTestEvent — tulis satu event + deltas langsung ke tabel supaya
// test papan poin tidak bergantung pada pipeline ingest (yang menegakkan
// invariant kronologis & gate season).
//
// Deltas diberi nilai netral: yang diuji papan adalah POIN, bukan Glicko.
func insertRankTestEvent(t *testing.T, st *SessionStore, ctx context.Context, schema,
	sourceID, date, kind string, scoreA, scoreB, target int, sides []playerSide) {
	t.Helper()

	var eventID string
	if err := st.pool.QueryRow(ctx, `
		INSERT INTO `+schema+`.rating_events
			(match_key, kind, source_id, source_fingerprint, stable_game_id, date,
			 game_order, title, score_a, score_b, target, phase, phase_weight, created_at, processed_at)
		VALUES ($1, $2, $3, 'test', $4, $5::date, '1', 'Rank Test', $6, $7, $8, 'regular', 1.0, now(), now())
		RETURNING id::text`,
		sourceID+"-mk", kind, sourceID, sourceID+"-g1", date, scoreA, scoreB, target).
		Scan(&eventID); err != nil {
		t.Fatalf("insert event %s: %v", sourceID, err)
	}

	// Peserta terdaftar sebagai source supaya konsisten dengan data nyata.
	if _, err := st.pool.Exec(ctx, `
		INSERT INTO `+schema+`.rating_sources (source_id, source_kind, fingerprint, finalized, last_ingested_seq, ingested_at)
		VALUES ($1, $2, 'test', true, 0, now())
		ON CONFLICT (source_id) DO NOTHING`, sourceID, kind); err != nil {
		t.Fatalf("insert source %s: %v", sourceID, err)
	}

	for _, sd := range sides {
		pid := resolveIDByAliasFuzzy(t, st, schema, sd.id)
		// Constraint: outcome hanya 'W' atau 'L'.
		outcome := "L"
		if (sd.team == "A" && scoreA > scoreB) || (sd.team == "B" && scoreB > scoreA) {
			outcome = "W"
		}
		if _, err := st.pool.Exec(ctx, `
			INSERT INTO `+schema+`.rating_deltas
				(event_id, player_id, team, outcome, expected, movm, delta, new_rating)
			VALUES ($1::uuid, $2::uuid, $3, $4, 0.5, 1.0, 0, 1500)`,
			eventID, pid, sd.team, outcome); err != nil {
			t.Fatalf("insert delta %s (%s): %v", sourceID, sd.id, err)
		}
	}
	_ = fmt.Sprintf
}
