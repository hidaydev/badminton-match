package store

import (
	"context"
	"fmt"
	"strconv"
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

	// ── Tier sticky: RP One/Two kelas A (kuat), RP Three..Six kelas D. ──
	// Pengali kekuatan lawan memakai TIER, bukan rating — jadi tier pemain
	// harus di-set eksplisit (registrasi test tidak mengisi tier).
	tierOf := map[string]string{"rp1": "A", "rp2": "A", "rp3": "D", "rp4": "D", "rp5": "D", "rp6": "D"}
	for id, tier := range tierOf {
		pid := resolveIDByAliasFuzzy(t, st, schema, id)
		if _, err := st.pool.Exec(ctx,
			`UPDATE `+schema+`.players SET tier = $2 WHERE id = $1::uuid`, pid, tier); err != nil {
			t.Fatalf("set tier %s: %v", id, err)
		}
	}

	// ── Siapkan rating_players manual: RP One kuat, sisanya lemah. ──
	// (Rating tetap di-seed untuk konsistensi data, tapi TIDAK lagi menjadi
	// basis pengali kekuatan lawan sejak revisi 2026-09-29.)
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

	// ── Pengali kekuatan lawan (basis TIER sticky) ──
	// RP One bermain melawan RP Three/RP Four. Nilai game mentah = 1 game ×
	// 250 (menang telak, margin = target). Pengali = band-tengah tier lawan
	// ÷ band-tengah tier populasi, dijepit. Basisnya tier, bukan rating:
	// rating 2000/1200 di test ini sengaja TIDAK memengaruhi hasil.
	//
	// Test ini mengunci basisnya: kalau seseorang mengembalikan pengali ke
	// rating Glicko, wantMult di bawah tidak lagi cocok.
	popAvg, err := st.popTierStrength(ctx, cfgForRankTest(t, st))
	if err != nil {
		t.Fatalf("populasi tier: %v", err)
	}
	if popAvg <= 0 {
		t.Fatal("rata-rata tier populasi 0 — pengali tidak akan pernah diuji")
	}
	cfgRT := cfgForRankTest(t, st)
	oppStrength, ok := tierStrength(cfgRT, "D") // RP Three/RP Four = tier D
	if !ok {
		t.Fatal("tier D tidak ada di ClassBands")
	}
	wantMult := oppStrength / popAvg
	if wantMult < 0.5 {
		wantMult = 0.5
	}
	if wantMult > 1.5 {
		wantMult = 1.5
	}
	wantEntryPoints := 250 * wantMult
	got := rpOne.Breakdown[0].Points
	if diff := got - wantEntryPoints; diff > 0.5 || diff < -0.5 {
		t.Fatalf("poin entri terbaik RP One = %.4f, want %.4f (250 × %.4f dari tier lawan) — pengali kekuatan lawan tidak diterapkan dengan benar",
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
		// Kode khusus test parity (papan + jalur satu-pemain) supaya tidak
		// bertabrakan dengan pemain test board di atas.
		"rpp1": "RPP One", "rpp2": "RPP Two", "rpp3": "RPP Three", "rpp4": "RPP Four",
		"rpd1": "RPD One", "rpd2": "RPD Two", "rpd3": "RPD Three", "rpd4": "RPD Four",
		"rz1": "RZ One", "rz2": "RZ Two", "rz3": "RZ Three", "rz4": "RZ Four",
		// Test poin turnamen (champion × rasio hasil).
		"rtp1": "RTP One", "rtp2": "RTP Two", "rtp3": "RTP Three", "rtp4": "RTP Four",
		// Test movement rank (snapshot + panah ^/v).
		"rm1": "RM One", "rm2": "RM Two", "rm3": "RM Three", "rm4": "RM Four",
		// Test as_of per-pemain.
		"ra1": "RA One", "ra2": "RA Two", "ra3": "RA Three", "ra4": "RA Four",
		// Test backfill achievement setelah rebuild.
		"ab1": "AB One", "ab2": "AB Two", "ab3": "AB Three", "ab4": "AB Four",
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

// TestIntegrationRankPointsPlayerParity — jalur satu-pemain
// (RankPointsForPlayer) harus menghasilkan angka IDENTIK dengan jalur papan
// penuh (RankPointsBoard) untuk SETIAP pemain.
//
// Kedua jalur menghitung dengan cara berbeda: papan penuh mengagregasi semua
// pemain di Go lalu memeringkat, jalur satu-pemain menyaring di SQL dan
// menghitung peringkat lewat count(*). Perbedaan implementasi seperti ini mudah
// menyimpang diam-diam (dan pernah menyimpang: peringkat meleset satu karena
// pembulatan poin), jadi kesamaannya dikunci di sini.
func TestIntegrationRankPointsPlayerParity(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	const prefix = "it-rankpar"
	players := []domain.Player{
		{ID: "rpp1", Name: "RPP One", Gender: "M", Tier: 5},
		{ID: "rpp2", Name: "RPP Two", Gender: "M", Tier: 5},
		{ID: "rpp3", Name: "RPP Three", Gender: "M", Tier: 1},
		{ID: "rpp4", Name: "RPP Four", Gender: "M", Tier: 1},
	}
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'RPP %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'rpp %'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'RPP %'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	latestDate, err := st.latestEventDate(ctx)
	if err != nil {
		t.Fatalf("latest date: %v", err)
	}
	if latestDate == "" {
		latestDate = "2026-09-27" // DB kosong: pakai tanggal tetap
	}
	for id, r := range map[string]float64{"rpp1": 2000, "rpp2": 2000, "rpp3": 1200, "rpp4": 1200} {
		if _, err := st.pool.Exec(ctx, `
			INSERT INTO `+schema+`.rating_players (player_id, rating, rd, games_played, wins, losses)
			VALUES ($1::uuid, $2, 80, 5, 3, 2)
			ON CONFLICT (player_id) DO UPDATE SET rating = EXCLUDED.rating, games_played = 5`,
			resolveIDByAliasFuzzy(t, st, schema, id), r); err != nil {
			t.Fatalf("rating %s: %v", id, err)
		}
	}

	// Dua sesi: pemain kuat menang, lalu menang lagi (skor beda).
	// Tanggal ditambatkan ke event terakhir di DB (window poin bergulir dari
	// sana), bukan tanggal tetap: kalau DB berisi data nyata yang lebih baru,
	// tanggal tetap bisa jatuh di luar window dan papan jadi kosong.
	base := dateMinusDays(t, latestDate, 7)
	insertRankTestEvent(t, st, ctx, schema, prefix+"s1", base, "session", 30, 20, 21, []playerSide{
		{id: "rpp1", team: "A"}, {id: "rpp2", team: "A"}, {id: "rpp3", team: "B"}, {id: "rpp4", team: "B"},
	})
	insertRankTestEvent(t, st, ctx, schema, prefix+"s2", latestDate, "session", 21, 15, 21, []playerSide{
		{id: "rpp1", team: "A"}, {id: "rpp3", team: "A"}, {id: "rpp2", team: "B"}, {id: "rpp4", team: "B"},
	})

	board, err := st.RankPointsBoard(ctx, "", 0)
	if err != nil {
		t.Fatalf("board: %v", err)
	}
	// Hanya pemain uji yang dibandingkan: papan penuh bisa memuat seluruh isi
	// DB (ratusan pemain), dan memanggil jalur satu-pemain untuk semuanya
	// membuat test ini lambat tanpa menambah cakupan.
	mine := map[string]bool{}
	for _, p := range players {
		mine[resolveIDByAliasFuzzy(t, st, schema, p.ID)] = true
	}
	compared := 0
	for _, full := range board.Rows {
		if !mine[full.PlayerID] {
			continue
		}
		compared++
		one, found, err := st.RankPointsForPlayer(ctx, full.PlayerID, "")
		if err != nil {
			t.Fatalf("%s: %v", full.Name, err)
		}
		if !found {
			t.Errorf("%s: ada di papan tapi jalur satu-pemain found=false", full.Name)
			continue
		}
		if one.Points != full.Points ||
			one.Rank != full.Rank ||
			one.CountedEntries != full.CountedEntries ||
			one.EntriesAvailable != full.EntriesAvailable ||
			one.ThinEvidence != full.ThinEvidence ||
			one.Name != full.Name {
			t.Errorf("%s berbeda:\n  satu-pemain: pts=%v rank=%d n=%d/%d thin=%v name=%q\n  papan      : pts=%v rank=%d n=%d/%d thin=%v name=%q",
				full.Name,
				one.Points, one.Rank, one.CountedEntries, one.EntriesAvailable, one.ThinEvidence, one.Name,
				full.Points, full.Rank, full.CountedEntries, full.EntriesAvailable, full.ThinEvidence, full.Name)
		}
	}
	if compared == 0 {
		t.Fatal("tidak ada pemain uji yang muncul di papan")
	}
	if compared != len(players) {
		t.Errorf("pemain uji di papan = %d, want %d", compared, len(players))
	}

	// Pemain tanpa entri di window → found=false (bukan error).
	if _, found, err := st.RankPointsForPlayer(ctx, "00000000-0000-0000-0000-0000000000ff", ""); err != nil || found {
		t.Errorf("pemain tanpa entri: found=%v err=%v (harus found=false, err=nil)", found, err)
	}
}

// TestIntegrationRankPointsTurnamen — poin turnamen = champion_points ×
// rasio hasil (§4.4), SATU entri per turnamen — bukan Σ gameValue per game
// (rumus sesi). Empat hasil dikunci sekaligus: juara, runner-up, gugur SF,
// ikut tanpa menang.
//
// Butuh baris rank_point_levels(kind='tournament_classic') di DB scratch
// (data prod — lihat docs/backend/README.md).
func TestIntegrationRankPointsTurnamen(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	const prefix = "it-rkturn"
	players := []domain.Player{
		{ID: "rtp1", Name: "RTP One", Gender: "M", Tier: 5},
		{ID: "rtp2", Name: "RTP Two", Gender: "M", Tier: 5},
		{ID: "rtp3", Name: "RTP Three", Gender: "M", Tier: 5},
		{ID: "rtp4", Name: "RTP Four", Gender: "M", Tier: 5},
	}
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'RTP %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'rtp %'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'RTP %'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	// champion_points dari konfigurasi (bukan hardcode) — kalau baris hilang
	// di scratch, gagal di sini dengan pesan jelas.
	var champion float64
	if err := st.pool.QueryRow(ctx,
		`SELECT champion_points FROM `+schema+`.rank_point_levels WHERE kind = 'tournament_classic'`).
		Scan(&champion); err != nil {
		t.Fatalf("baca rank_point_levels (scratch harus punya data, lihat docs/backend/README.md): %v", err)
	}

	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	date := dateAfterAllEvents(t, st, schema)
	src := prefix + "-1"

	// Satu turnamen, empat match beda fase (match_key & game_order unik —
	// rating_events_order_uniq & match_key unik).
	type ev struct {
		mk, phase string
		order     string
		scoreA    int
		scoreB    int
		sides     []playerSide
	}
	evs := []ev{
		{"mk-grup", "group", "1", 21, 15, []playerSide{{id: "rtp1", team: "A"}, {id: "rtp2", team: "B"}}},
		{"mk-qf", "qf", "2", 21, 10, []playerSide{{id: "rtp4", team: "A"}}},
		{"mk-sf", "sf", "3", 21, 12, []playerSide{{id: "rtp1", team: "B"}}},
		{"mk-fin", "final", "4", 21, 18, []playerSide{{id: "rtp3", team: "A"}, {id: "rtp4", team: "B"}}},
	}
	for _, e := range evs {
		var eventID string
		if err := st.pool.QueryRow(ctx, `
			INSERT INTO `+schema+`.rating_events
				(match_key, kind, source_id, source_fingerprint, stable_game_id, date,
				 game_order, title, score_a, score_b, target, phase, phase_weight, created_at, processed_at)
			VALUES ($1, 'tournament_classic', $2, 'test', $3, $4::date, $5, 'Rank Turnamen',
			        $6, $7, 30, $8, 1.0, now(), now())
			RETURNING id::text`,
			e.mk, src, e.mk, date, e.order, e.scoreA, e.scoreB, e.phase).
			Scan(&eventID); err != nil {
			t.Fatalf("insert event %s: %v", e.mk, err)
		}
		if _, err := st.pool.Exec(ctx, `
			INSERT INTO `+schema+`.rating_sources (source_id, source_kind, fingerprint, finalized, last_ingested_seq, ingested_at)
			VALUES ($1, 'tournament_classic', 'test', true, 0, now())
			ON CONFLICT (source_id) DO NOTHING`, src); err != nil {
			t.Fatalf("insert source: %v", err)
		}
		for _, sd := range e.sides {
			pid := resolveIDByAliasFuzzy(t, st, schema, sd.id)
			outcome := "L"
			if (sd.team == "A" && e.scoreA > e.scoreB) || (sd.team == "B" && e.scoreB > e.scoreA) {
				outcome = "W"
			}
			if _, err := st.pool.Exec(ctx, `
				INSERT INTO `+schema+`.rating_deltas
					(event_id, player_id, team, outcome, expected, movm, delta, new_rating)
				VALUES ($1::uuid, $2::uuid, $3, $4, 0.5, 1.0, 0, 1500)`,
				eventID, pid, sd.team, outcome); err != nil {
				t.Fatalf("insert delta %s: %v", e.mk, err)
			}
		}
	}

	board, err := st.RankPointsBoard(ctx, "", 200)
	if err != nil {
		t.Fatalf("board: %v", err)
	}
	byName := map[string]RankPointRow{}
	for _, r := range board.Rows {
		byName[r.Name] = r
	}
	// Juara ×1.0, runner-up ×0.85, gugur SF ×0.7, ikut tanpa menang ×0.2.
	want := map[string]float64{
		"RTP Three": champion * 1.0,  // menang final
		"RTP Four":  champion * 0.85, // menang qf, kalah final
		"RTP One":   champion * 0.7,  // menang grup, kalah sf
		"RTP Two":   champion * 0.2,  // kalah grup, tanpa kemenangan
	}
	for name, w := range want {
		r, ok := byName[name]
		if !ok {
			t.Fatalf("%s tidak ada di papan", name)
		}
		if r.Points != w {
			t.Errorf("%s = %v, want %v (champion=%v) — poin turnamen harus champion×rasio, bukan Σ gameValue",
				name, r.Points, w, champion)
		}
		if r.EntriesAvailable != 1 || r.CountedEntries != 1 {
			t.Errorf("%s entries = %d/%d, want 1/1 — turnamen = satu entri", name, r.CountedEntries, r.EntriesAvailable)
		}
	}

	// Jalur per-pemain IDENTIK dengan papan — termasuk Rank (audit ke-7:
	// CTE SQL lama menghitung rank dengan rumus sesi sehingga menyimpang
	// begitu poin turnamen ada).
	pr, found, err := st.RankPointsForPlayer(ctx, resolveIDByAlias(t, st, "rtp four"), "")
	if err != nil || !found {
		t.Fatalf("RankPointsForPlayer: found=%v err=%v", found, err)
	}
	if pr.Points != want["RTP Four"] {
		t.Errorf("per-pemain RTP Four = %v, want %v", pr.Points, want["RTP Four"])
	}
	if pr.Breakdown != nil && len(pr.Breakdown) > 0 && pr.Breakdown[0].Result != "runner_up" {
		t.Errorf("breakdown result = %q, want runner_up", pr.Breakdown[0].Result)
	}
	var boardRow *RankPointRow
	for i := range board.Rows {
		if board.Rows[i].PlayerID == pr.PlayerID {
			boardRow = &board.Rows[i]
			break
		}
	}
	if boardRow == nil {
		t.Fatalf("pemain %s tidak ada di papan", pr.PlayerID)
	}
	if boardRow.Rank != pr.Rank || boardRow.Points != pr.Points ||
		boardRow.CountedEntries != pr.CountedEntries || boardRow.EntriesAvailable != pr.EntriesAvailable {
		t.Errorf("parity per-pemain vs papan: rank %d/%d, points %v/%v, entries %d/%d vs %d/%d",
			pr.Rank, boardRow.Rank, pr.Points, boardRow.Points,
			pr.CountedEntries, pr.EntriesAvailable, boardRow.EntriesAvailable, boardRow.EntriesAvailable)
	}

	// Fallback: baris level disabled → turnamen jatuh ke rumus sesi §4.5
	// (bukan 0, bukan champion). Mengunci jalur fallback supaya tak terganti
	// diam-diam jadi level-only.
	if _, err := st.pool.Exec(ctx,
		`UPDATE `+schema+`.rank_point_levels SET enabled = false WHERE kind = 'tournament_classic'`); err != nil {
		t.Fatalf("disable level: %v", err)
	}
	t.Cleanup(func() {
		_, _ = st.pool.Exec(ctx,
			`UPDATE `+schema+`.rank_point_levels SET enabled = true WHERE kind = 'tournament_classic'`)
	})
	fb, found, err := st.RankPointsForPlayer(ctx, resolveIDByAlias(t, st, "rtp three"), "")
	if err != nil || !found {
		t.Fatalf("fallback per-pemain: found=%v err=%v", found, err)
	}
	// RTP Three: satu match final menang 21-18, target 30 →
	// 250 × (0.5 + 0.5 × 3/30) = 137.5 → 138 (round board).
	if fb.Points == want["RTP Three"] || fb.Points >= 1000 {
		t.Errorf("fallback enabled=false: points = %v, want rumus sesi (~138), bukan champion %v",
			fb.Points, want["RTP Three"])
	}
}

// TestIntegrationRankMovement — panah movement (^/v) di papan.
//
// Snapshot ditulis manual untuk tanggal acuan lama (mewakili papan beberapa
// hari lalu), lalu papan hari ini dibandingkan. Juga membuktikan
// CaptureRankSnapshot idempoten per (as_of, player_id).
func TestIntegrationRankMovement(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	const prefix = "it-rankmove"
	players := []domain.Player{
		{ID: "rm1", Name: "RM One", Gender: "M", Tier: 5},
		{ID: "rm2", Name: "RM Two", Gender: "M", Tier: 5},
		{ID: "rm3", Name: "RM Three", Gender: "M", Tier: 1},
		{ID: "rm4", Name: "RM Four", Gender: "M", Tier: 1},
	}
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rank_snapshots WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'RM %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE 'it-rankmove%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE 'it-rankmove%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE 'it-rankmove%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE 'it-rankmove%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'RM %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'rm %'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'RM %'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	// Tier sticky: RM One/Two kelas A, RM Three/Four kelas D. Pengali
	// kekuatan lawan memakai TIER (bukan rating), jadi tier harus di-set.
	for id, tier := range map[string]string{"rm1": "A", "rm2": "A", "rm3": "D", "rm4": "D"} {
		pid := resolveIDByAliasFuzzy(t, st, schema, id)
		if _, err := st.pool.Exec(ctx,
			`UPDATE `+schema+`.players SET tier = $2 WHERE id = $1::uuid`, pid, tier); err != nil {
			t.Fatalf("set tier %s: %v", id, err)
		}
	}
	for id, r := range map[string]float64{"rm1": 2000, "rm2": 2000, "rm3": 1200, "rm4": 1200} {
		pid := resolveIDByAliasFuzzy(t, st, schema, id)
		if _, err := st.pool.Exec(ctx, `
			INSERT INTO `+schema+`.rating_players (player_id, rating, rd, peak_rating, games_played, wins, losses)
			VALUES ($1::uuid, $2, 100, $2, 1, 1, 0)
			ON CONFLICT (player_id) DO UPDATE SET rating = EXCLUDED.rating, rd = 100, peak_rating = EXCLUDED.peak_rating`,
			pid, r); err != nil {
			t.Fatalf("seed rating %s: %v", id, err)
		}
	}

	// RM One jauh di atas RM Two: RM One menang telak 3 sesi, RM Two kalah.
	baseDate := "2026-09-27"
	for i := 0; i < 3; i++ {
		insertRankTestEvent(t, st, ctx, schema, prefix+"-s"+pad2(i), dateMinusDays(t, baseDate, i), "session",
			21, 0, 21, []playerSide{
				{id: "rm1", team: "A"}, {id: "rm2", team: "A"},
				{id: "rm3", team: "B"}, {id: "rm4", team: "B"},
			})
	}

	board, err := st.RankPointsBoard(ctx, baseDate, 5000)
	if err != nil {
		t.Fatalf("board: %v", err)
	}
	if len(board.Rows) < 2 {
		t.Fatalf("rows=%d, want >= 2", len(board.Rows))
	}
	// Tanpa snapshot sebelumnya: tidak ada movement.
	for _, r := range board.Rows {
		if r.PrevRank != nil || r.RankDelta != nil {
			t.Fatalf("%s sudah punya movement tanpa snapshot sebelumnya", r.Name)
		}
	}

	// Snapshot "hari sebelumnya": RM Two di atas RM One (posisi terbalik),
	// RM Three di bawah. Tanggal acuan lebih tua → jadi pembanding.
	prevDate := dateMinusDays(t, baseDate, 3)
	rankPrev := map[string]int{"rm1": 2, "rm2": 1, "rm4": 3}
	for id, rk := range rankPrev {
		pid := resolveIDByAliasFuzzy(t, st, schema, id)
		if _, err := st.pool.Exec(ctx, `
			INSERT INTO `+schema+`.rank_snapshots (as_of, player_id, rank, points)
			VALUES ($1::date, $2::uuid, $3, 0)`, prevDate, pid, rk); err != nil {
			t.Fatalf("snapshot %s: %v", id, err)
		}
	}

	board2, err := st.RankPointsBoard(ctx, baseDate, 5000)
	if err != nil {
		t.Fatalf("board2: %v", err)
	}
	byName := map[string]RankPointRow{}
	for _, r := range board2.Rows {
		byName[r.Name] = r
	}
	// Papan nyata di sini: RM Three & RM Four rank 1 (984 — menang melawan
	// pemain kuat), RM One & RM Two rank 3 (590 — menang melawan pemain
	// lemah). Pengali kekuatan lawan, bukan urutan tim. Snapshot pembanding
	// menaruh RM One di 2 dan RM Two di 1, jadi:
	//   RM One: 2 → 3 = turun, delta -1.
	//   RM Two: 1 → 3 = turun, delta -2.
	if r := byName["RM One"]; r.RankDelta == nil || *r.RankDelta != -1 || r.PrevRank == nil || *r.PrevRank != 2 {
		t.Errorf("RM One: delta=%s prev=%s, want -1 dari 2", fmtIntPtr(r.RankDelta), fmtIntPtr(r.PrevRank))
	}
	if r := byName["RM Two"]; r.RankDelta == nil || *r.RankDelta != -2 || r.PrevRank == nil || *r.PrevRank != 1 {
		t.Errorf("RM Two: delta=%s prev=%s, want -2 dari 1", fmtIntPtr(r.RankDelta), fmtIntPtr(r.PrevRank))
	}
	// RM Three: tidak ada di snapshot sebelumnya → null (pemain baru di papan).
	if r := byName["RM Three"]; r.PrevRank != nil || r.RankDelta != nil {
		t.Errorf("RM Three: prev=%v delta=%v, want null (tanpa pembanding)", r.PrevRank, r.RankDelta)
	}

	// CaptureRankSnapshot: idempoten per (as_of, player_id) → jumlah baris
	// papan hari ini tetap, bukan bertambah pada pemanggilan kedua.
	n1, err := st.CaptureRankSnapshot(ctx)
	if err != nil {
		t.Fatalf("capture 1: %v", err)
	}
	n2, err := st.CaptureRankSnapshot(ctx)
	if err != nil {
		t.Fatalf("capture 2: %v", err)
	}
	if n1 != n2 {
		t.Fatalf("capture: n1=%d n2=%d, want sama (idempoten)", n1, n2)
	}
	var cnt1, cnt2 int
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.rank_snapshots WHERE as_of = $1::date`, baseDate).Scan(&cnt1); err != nil {
		t.Fatalf("count: %v", err)
	}
	if _, err := st.CaptureRankSnapshot(ctx); err != nil {
		t.Fatalf("capture 3: %v", err)
	}
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.rank_snapshots WHERE as_of = $1::date`, baseDate).Scan(&cnt2); err != nil {
		t.Fatalf("count2: %v", err)
	}
	if cnt1 != cnt2 {
		t.Fatalf("snapshot hari ini bertambah: %d → %d (harus idempoten)", cnt1, cnt2)
	}
	// Snapshot hari ini = papan terisi + RM Three (yang tadi null) kini punya
	// baris sendiri pada as_of hari ini.
	if cnt1 < len(board2.Rows) {
		t.Errorf("snapshot hari ini=%d baris, papan=%d baris", cnt1, len(board2.Rows))
	}

	// Movement harus tetap dibandingkan dengan snapshot SEBELUM asOf, bukan
	// dengan snapshot hari ini yang baru saja ditulis. Kalau pembandingnya
	// <= asOf (termasuk snapshot hari ini), papan akan dibandingkan dengan
	// dirinya sendiri → delta 0 dan panah hilang.
	board3, err := st.RankPointsBoard(ctx, baseDate, 5000)
	if err != nil {
		t.Fatalf("board3: %v", err)
	}
	for i := range board3.Rows {
		if board3.Rows[i].Name == "RM One" {
			if board3.Rows[i].RankDelta == nil || *board3.Rows[i].RankDelta != -1 {
				t.Errorf("setelah snapshot hari ini ditulis, RM One delta=%s, want tetap -1",
					fmtIntPtr(board3.Rows[i].RankDelta))
			}
		}
	}
}

// fmtIntPtr — cetak *int untuk pesan test (nil → "null").
func fmtIntPtr(p *int) string {
	if p == nil {
		return "null"
	}
	return strconv.Itoa(*p)
}

// cfgForRankTest — config rating aktif untuk test (memuat ClassBands).
func cfgForRankTest(t *testing.T, st *SessionStore) domain.RatingConfig {
	t.Helper()
	cfg, err := st.LoadRatingConfig(context.Background(), false)
	if err != nil {
		t.Fatalf("LoadRatingConfig: %v", err)
	}
	return cfg
}

// TestIntegrationRankPointsForPlayerAsOf — as_of dihormati di jalur
// per-pemain, sama seperti papan.
//
// Regresi yang dikunci: dulu RankPointsForPlayer selalu memakai tanggal event
// terakhir, sehingga halaman detail pemain menampilkan peringkat/poin yang
// berbeda dari papan pada tanggal yang sedang dilihat pengguna.
func TestIntegrationRankPointsForPlayerAsOf(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	const prefix = "it-rasof"
	players := []domain.Player{
		{ID: "ra1", Name: "RA One", Gender: "M", Tier: 3},
		{ID: "ra2", Name: "RA Two", Gender: "M", Tier: 3},
		{ID: "ra3", Name: "RA Three", Gender: "M", Tier: 1},
		{ID: "ra4", Name: "RA Four", Gender: "M", Tier: 1},
	}
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'RA %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'ra %'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'RA %'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	tierOf := map[string]string{"ra1": "C", "ra2": "C", "ra3": "D", "ra4": "D"}
	for id, tier := range tierOf {
		pid := resolveIDByAliasFuzzy(t, st, schema, id)
		if _, err := st.pool.Exec(ctx, `UPDATE `+schema+`.players SET tier = $2 WHERE id = $1::uuid`, pid, tier); err != nil {
			t.Fatalf("tier %s: %v", id, err)
		}
	}

	// Dua sesi di tanggal berbeda.
	early := "2026-08-01"
	late := "2026-09-27"
	insertRankTestEvent(t, st, ctx, schema, prefix+"-a", early, "session", 21, 0, 30, []playerSide{
		{id: "ra1", team: "A"}, {id: "ra2", team: "A"},
		{id: "ra3", team: "B"}, {id: "ra4", team: "B"},
	})
	insertRankTestEvent(t, st, ctx, schema, prefix+"-b", late, "session", 21, 0, 30, []playerSide{
		{id: "ra1", team: "A"}, {id: "ra2", team: "A"},
		{id: "ra3", team: "B"}, {id: "ra4", team: "B"},
	})

	pid := resolveIDByAliasFuzzy(t, st, schema, "ra3")

	// asOf awal: hanya sesi pertama dalam window → 1 entri.
	earlyRow, found, err := st.RankPointsForPlayer(ctx, pid, early)
	if err != nil || !found {
		t.Fatalf("asOf awal: found=%v err=%v", found, err)
	}
	// asOf akhir: dua entri.
	lateRow, found, err := st.RankPointsForPlayer(ctx, pid, late)
	if err != nil || !found {
		t.Fatalf("asOf akhir: found=%v err=%v", found, err)
	}
	if lateRow.EntriesAvailable <= earlyRow.EntriesAvailable {
		t.Fatalf("as_of tidak dihormati: entri awal=%d, akhir=%d (harus bertambah)",
			earlyRow.EntriesAvailable, lateRow.EntriesAvailable)
	}

	// Paritas dengan papan pada tanggal yang sama.
	board, err := st.RankPointsBoard(ctx, early, 500)
	if err != nil {
		t.Fatalf("board: %v", err)
	}
	for i := range board.Rows {
		if board.Rows[i].PlayerID == pid {
			if board.Rows[i].Points != earlyRow.Points || board.Rows[i].Rank != earlyRow.Rank {
				t.Fatalf("per-pemain != papan pada as_of %s: %v/%d vs %v/%d",
					early, earlyRow.Points, earlyRow.Rank, board.Rows[i].Points, board.Rows[i].Rank)
			}
			return
		}
	}
	t.Fatalf("pemain tidak ada di papan as_of %s", early)
}
