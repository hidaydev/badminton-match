package store

import (
	"context"
	"fmt"
	"testing"
	"time"

	"majadu-api/internal/domain"
)

// ratingMappingSnapshot — ambil pemetaan event→pemain untuk sebuah source,
// sebagai tolok ukur pemetaan sebelum hilang.
func ratingMappingSnapshot(t *testing.T, st *SessionStore, schema, sourceID string) map[string]string {
	t.Helper()
	rows, err := st.pool.Query(t.Context(), `
		SELECT re.stable_game_id, rd.player_id::text || '|' || rd.team
		FROM `+schema+`.rating_events re
		JOIN `+schema+`.rating_deltas rd ON rd.event_id = re.id
		WHERE re.source_id = $1
		ORDER BY re.stable_game_id, rd.player_id, rd.team`, sourceID)
	if err != nil {
		t.Fatalf("baca pemetaan: %v", err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var game, val string
		if err := rows.Scan(&game, &val); err != nil {
			t.Fatal(err)
		}
		out[game] += val + ","
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(out) == 0 {
		t.Fatalf("source %s tidak punya pemetaan — prasyarat gagal", sourceID)
	}
	return out
}

// TestIntegrationRebuildRestoresMissingDeltas — rebuild memulihkan rating_deltas
// dari SUMBER KEBENARAN (sessions + scheduled_games + session_players).
//
// rating_deltas adalah bahan baku papan poin, tapi ia sendiri TIDAK sumber
// kebenaran: kalau isinya hilang, rekonstruksi dari sesi-lah yang membangunnya
// kembali. Tanpa itu ketergantungan melingkar: rebuild membaca deltas yang
// akan dihapusnya sendiri.
//
// Diuji dengan pemain ABSENT karena itu aturan rekonstruksi yang paling mudah
// salah (pemain absen tidak boleh muncul di pemetaan). Aturan lain
// (skipped_player_refs, slot player_id NULL) diverifikasi terhadap data
// produksi: rekonstruksi menghasilkan 2541 baris persis sama dengan
// rating_deltas prod, 0 selisih.
func TestIntegrationRebuildRestoresMissingDeltas(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	const prefix = "it-recover"
	players := []domain.Player{
		{ID: "rz1", Name: "RZ One", Gender: "M", Tier: 3},
		{ID: "rz2", Name: "RZ Two", Gender: "M", Tier: 3},
		{ID: "rz3", Name: "RZ Three", Gender: "M", Tier: 1},
		{ID: "rz4", Name: "RZ Four", Gender: "M", Tier: 1},
	}
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.scheduled_games WHERE session_id IN (SELECT id FROM `+schema+`.sessions WHERE share_code LIKE '`+prefix+`%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'RZ %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'rz %'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'RZ %'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}

	// Tanggal setelah season_start dan setelah event terakhir (invariant kronologis).
	var date string
	if err := st.pool.QueryRow(ctx, `
		SELECT (GREATEST(
			(SELECT (value #>> '{}')::date FROM `+schema+`.rating_config WHERE key='season_start'),
			COALESCE((SELECT max(date) FROM `+schema+`.rating_events), CURRENT_DATE)
		) + INTERVAL '1 day')::date::text`).Scan(&date); err != nil {
		t.Fatalf("hitung tanggal: %v", err)
	}

	id := prefix + "-sess"
	snap := &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "RZ Recover", Date: date, Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: 4, CourtNames: []string{"C1"},
		},
		Players: players, FixMatches: []domain.FixMatch{},
		Schedule:      []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"rz1", "rz2"}, TeamB: [2]string{"rz3", "rz4"}}},
		PlayedGames:   []string{"0-0"},
		GameScores:    map[string]domain.GameScore{"0-0": {A: 21, B: 10}},
		AbsentPlayers: []string{"rz4"}, // pemain absen: tidak boleh muncul di pemetaan
	}
	if _, err := st.Save(ctx, id, snap); err != nil {
		t.Fatalf("save: %v", err)
	}
	saveLock(t, st, ctx, id)
	if r, err := st.IngestSession(ctx, id); err != nil || r.Processed != 1 {
		t.Fatalf("ingest: %+v %v", r, err)
	}

	want := ratingMappingSnapshot(t, st, schema, id)
	t.Logf("pemetaan asli: %v", want)

	// ── rusakkan: buang rating_deltas milik sesi ini (simulasi hilang) ──
	if _, err := st.pool.Exec(ctx, `
		DELETE FROM `+schema+`.rating_deltas
		WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%')`); err != nil {
		t.Fatalf("hapus deltas: %v", err)
	}
	var left int
	if err := st.pool.QueryRow(ctx,
		`SELECT count(*) FROM `+schema+`.rating_deltas WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%')`).
		Scan(&left); err != nil {
		t.Fatal(err)
	}
	if left != 0 {
		t.Fatalf("prasyarat gagal: masih ada %d deltas", left)
	}

	// ── pulihkan ──
	if _, err := st.RebuildAll(ctx); err != nil {
		t.Fatalf("rebuild: %v", err)
	}

	got := ratingMappingSnapshot(t, st, schema, id)
	if len(got) != len(want) {
		t.Errorf("pemetaan game: dapat %d, want %d", len(got), len(want))
	}
	for game, wantVal := range want {
		gotVal, ok := got[game]
		if !ok {
			t.Errorf("game %s hilang setelah rebuild", game)
			continue
		}
		if gotVal != wantVal {
			t.Errorf("game %s: pemetaan %q, want %q", game, gotVal, wantVal)
		}
	}

	// Pemain absen tidak boleh muncul sebagai hasil rekonstruksi.
	absentID := resolveIDByAlias(t, st, "rz four")
	var absentN int
	if err := st.pool.QueryRow(ctx, `
		SELECT count(*) FROM `+schema+`.rating_deltas rd
		JOIN `+schema+`.rating_events re ON re.id = rd.event_id
		WHERE re.source_id LIKE '`+prefix+`%' AND rd.player_id = $1::uuid`, absentID).Scan(&absentN); err != nil {
		t.Fatal(err)
	}
	if absentN != 0 {
		t.Errorf("pemain absen dapat %d delta setelah rekonstruksi, want 0", absentN)
	}
}

// TestIntegrationRebuildPreservesPreSeasonDeltas — rebuild TIDAK menghapus
// rating_deltas di bawah season_start.
//
// Bug yang dijaga test ini: DELETE rating_deltas pernah tanpa syarat, padahal
// yang diproses ulang hanya events >= season_start. Akibatnya begitu musim
// bertambah (season_start maju), deltas seluruh musim sebelumnya terhapus dan
// tidak pernah ditulis lagi — papan poin ber-window untuk rentang yang
// menyeberang batas musim jadi kosong permanen.
func TestIntegrationRebuildPreservesPreSeasonDeltas(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	players := []domain.Player{
		{ID: "rpd1", Name: "RPD One", Gender: "M", Tier: 3},
		{ID: "rpd2", Name: "RPD Two", Gender: "M", Tier: 3},
		{ID: "rpd3", Name: "RPD Three", Gender: "M", Tier: 1},
		{ID: "rpd4", Name: "RPD Four", Gender: "M", Tier: 1},
	}
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE 'it-rpd%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE 'it-rpd%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE 'it-rpd%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'RPD %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'rpd %'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'RPD %'`)
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.rating_config SET value='"2026-05-23"' WHERE key='season_start'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}

	// Event musim lama (jauh di bawah season_start) + pemetaannya.
	legacyDate := "2020-01-04"
	insertRankTestEvent(t, st, ctx, schema, "it-rpd-legacy", legacyDate, "session",
		21, 0, 21, []playerSide{
			{id: "rpd1", team: "A"}, {id: "rpd2", team: "A"},
			{id: "rpd3", team: "B"}, {id: "rpd4", team: "B"},
		})
	before := ratingMappingSnapshot(t, st, schema, "it-rpd-legacy")
	t.Logf("deltas musim lama sebelum rebuild: %d game", len(before))

	// season_start tetap 2026-05-23 → event 2020 ada DI LUAR musim.
	if _, err := st.RebuildAll(ctx); err != nil {
		t.Fatalf("rebuild: %v", err)
	}

	after := ratingMappingSnapshot(t, st, schema, "it-rpd-legacy")
	if len(after) == 0 {
		t.Fatal("rating_deltas musim lama HILANG setelah RebuildAll — rebuild menghapus deltas di luar musim")
	}
	for game, wantVal := range before {
		if gotVal := after[game]; gotVal != wantVal {
			t.Errorf("game %s: %q setelah rebuild, want %q", game, gotVal, wantVal)
		}
	}

	// Dan totals: semua deltas di luar musim utuh.
	var outside int
	if err := st.pool.QueryRow(ctx, `
		SELECT count(*) FROM `+schema+`.rating_deltas rd
		JOIN `+schema+`.rating_events re ON re.id = rd.event_id
		WHERE re.date < (SELECT (value #>> '{}')::date FROM `+schema+`.rating_config WHERE key='season_start')`).
		Scan(&outside); err != nil {
		t.Fatal(err)
	}
	if outside == 0 {
		t.Error("tidak ada deltas tersisa di luar musim")
	}
	_ = fmt.Sprintf
	_ = time.Now
}

// TestIntegrationRebuildRatesOneSidedGame — game dengan satu sisi habis
// di-skip tetap harus dinilai rebuild.
//
// Bug yang dijaga test ini: loop rebuild membuang event begitu salah satu
// sisi tidak punya pemain, padahal ingest tetap menilainya — sisi yang semua
// pemainnya digantikan masih "real" (mereka hadir, hanya digantikan di game
// ini), dan lawan penggantinya disintesis dari tier assigned mereka.
// Akibat bug itu delta pemain yang benar-benar main hilang permanen setiap
// rebuild (terukur di data produksi: 1 event, 2 delta lenyap tiap kali).
//
// Pemetaan rekonstruksi juga harus ikut membawa pemain yang di-skip (dengan
// flag), bukan dibuang — tanpa mereka, sisi yang kosong itu dianggap tidak
// real dan game dianggap tidak layak dinilai.
func TestIntegrationRebuildRatesOneSidedGame(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	const prefix = "it-onesided"
	players := []domain.Player{
		{ID: "ros1", Name: "ROS One", Gender: "M", Tier: 3},
		{ID: "ros2", Name: "ROS Two", Gender: "M", Tier: 3},
		{ID: "ros3", Name: "ROS Three", Gender: "M", Tier: 1},
		{ID: "ros4", Name: "ROS Four", Gender: "M", Tier: 1},
	}
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.scheduled_game_players WHERE scheduled_game_internal_id IN (SELECT sg.internal_id FROM `+schema+`.scheduled_games sg JOIN `+schema+`.sessions s ON s.id=sg.session_id WHERE s.share_code LIKE '`+prefix+`%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.scheduled_games WHERE session_id IN (SELECT id FROM `+schema+`.sessions WHERE share_code LIKE '`+prefix+`%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'ROS %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'ros %'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'ROS %'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}

	var date string
	if err := st.pool.QueryRow(ctx, `
		SELECT (GREATEST(
			(SELECT (value #>> '{}')::date FROM `+schema+`.rating_config WHERE key='season_start'),
			COALESCE((SELECT max(date) FROM `+schema+`.rating_events), CURRENT_DATE)
		) + INTERVAL '1 day')::date::text`).Scan(&date); err != nil {
		t.Fatalf("hitung tanggal: %v", err)
	}

	id := prefix + "-sess"
	snap := &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "ROS", Date: date, Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: 4, CourtNames: []string{"C1"},
		},
		Players: players, FixMatches: []domain.FixMatch{},
		Schedule:       []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"ros1", "ros2"}, TeamB: [2]string{"ros3", "ros4"}}},
		PlayedGames:    []string{"0-0"},
		GameScores:     map[string]domain.GameScore{"0-0": {A: 21, B: 10}},
		SkippedPlayers: map[string][]string{"0-0": {"ros3", "ros4"}}, // sisi B habis di-skip
	}
	if _, err := st.Save(ctx, id, snap); err != nil {
		t.Fatalf("save: %v", err)
	}
	saveLock(t, st, ctx, id)
	if r, err := st.IngestSession(ctx, id); err != nil || r.Processed != 1 {
		t.Fatalf("ingest: %+v %v", r, err)
	}

	// Prasyarat: jalur ingest menilai game ini (hanya sisi A dapat delta).
	want := ratingMappingSnapshot(t, st, schema, id)
	t.Logf("pemetaan dari ingest: %v", want)
	if len(want) != 1 {
		t.Fatalf("prasyarat gagal: ingest menghasilkan %d game, want 1", len(want))
	}
	var nDelta int
	if err := st.pool.QueryRow(ctx, `
		SELECT count(*) FROM `+schema+`.rating_deltas rd
		JOIN `+schema+`.rating_events re ON re.id = rd.event_id
		WHERE re.source_id = $1`, id).Scan(&nDelta); err != nil {
		t.Fatal(err)
	}
	if nDelta != 2 {
		t.Fatalf("prasyarat gagal: ingest menghasilkan %d delta, want 2 (hanya sisi A)", nDelta)
	}

	if _, err := st.RebuildAll(ctx); err != nil {
		t.Fatalf("rebuild: %v", err)
	}

	// Delta pemain sisi A harus dipulihkan, dan tetap tidak ada delta untuk
	// pemain yang di-skip.
	var after int
	if err := st.pool.QueryRow(ctx, `
		SELECT count(*) FROM `+schema+`.rating_deltas rd
		JOIN `+schema+`.rating_events re ON re.id = rd.event_id
		WHERE re.source_id = $1`, id).Scan(&after); err != nil {
		t.Fatal(err)
	}
	if after != nDelta {
		t.Errorf("delta setelah rebuild = %d, want %d — game satu sisi tidak diproses ulang", after, nDelta)
	}
	for game, wantVal := range want {
		if got := ratingMappingSnapshot(t, st, schema, id)[game]; got != wantVal {
			t.Errorf("game %s: pemetaan %q, want %q", game, got, wantVal)
		}
	}

	// Pemain yang di-skip tidak boleh menerima delta.
	for _, ref := range []string{"ros three", "ros four"} {
		pid := resolveIDByAlias(t, st, ref)
		var n int
		if err := st.pool.QueryRow(ctx, `
			SELECT count(*) FROM `+schema+`.rating_deltas rd
			JOIN `+schema+`.rating_events re ON re.id=rd.event_id
			WHERE re.source_id=$1 AND rd.player_id=$2::uuid`, id, pid).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n != 0 {
			t.Errorf("pemain di-skip %s dapat %d delta, want 0", ref, n)
		}
	}
}
