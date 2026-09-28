package store

import (
	"context"
	"testing"

	"majadu-api/internal/domain"
)

// Test-file ini mengunci tiga divergensi rebuild vs ingest (audit):
//
//  1. Gate journey (registered_at > tanggal sesi → tidak dapat delta) hanya
//     berlaku di jalur REKONSTRUKSI — delta lama dari rating_deltas TETAP
//     dipertahankan meski registered_at berubah belakangan (kasus prod: 6
//     delta "Zaki" yang registered_at-nya di-set setelah delta diberikan).
//  2. Pemain journey-gagal tanpa delta TIDAK ditambahkan oleh rekonstruksi
//     (rebuild tidak boleh memberi yang sudah ditolak ingest).
//  3. absent_policy=count: pemain absent tetap dinilai oleh rebuild.
//
// Semua test ber-prefix unik + cleanup penuh (suite hanya valid di DB kosong).

// dateAfterAllEvents — tanggal sesi aman: setelah max(date) & season_start
// (invariant kronologis ingest).
func dateAfterAllEvents(t *testing.T, st *SessionStore, schema string) string {
	t.Helper()
	var d string
	if err := st.pool.QueryRow(context.Background(), `
		SELECT (GREATEST(
			(SELECT (value #>> '{}')::date FROM `+schema+`.rating_config WHERE key='season_start'),
			COALESCE((SELECT max(date) FROM `+schema+`.rating_events), CURRENT_DATE)
		) + INTERVAL '1 day')::date::text`).Scan(&d); err != nil {
		t.Fatalf("hitung tanggal: %v", err)
	}
	return d
}

// countPlayerDeltas — jumlah baris rating_deltas milik satu pemain (global).
func countPlayerDeltas(t *testing.T, st *SessionStore, schema, pid string) int {
	t.Helper()
	var n int
	if err := st.pool.QueryRow(context.Background(),
		`SELECT count(*) FROM `+schema+`.rating_deltas WHERE player_id = $1::uuid`,
		pid).Scan(&n); err != nil {
		t.Fatalf("hitung deltas: %v", err)
	}
	return n
}

// rbjFixture — sesi 1 game, 4 pemain, ter-ingest (semua dpt delta).
func rbjFixture(t *testing.T, st *SessionStore, schema, prefix string, absent []string) (ctx context.Context, date string) {
	t.Helper()
	ctx = context.Background()
	players := []domain.Player{
		{ID: prefix + "1", Name: prefix + " One", Gender: "M", Tier: 3},
		{ID: prefix + "2", Name: prefix + " Two", Gender: "M", Tier: 3},
		{ID: prefix + "3", Name: prefix + " Three", Gender: "M", Tier: 3},
		{ID: prefix + "4", Name: prefix + " Four", Gender: "M", Tier: 3},
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}
	id := prefix + "-sess"
	date = dateAfterAllEvents(t, st, schema)
	snap := &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: prefix, Date: date, Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: 4, CourtNames: []string{"C1"},
		},
		Players: players, FixMatches: []domain.FixMatch{},
		Schedule: []domain.ScheduleSlot{{Slot: 0, Court: 0,
			TeamA: [2]string{prefix + "1", prefix + "2"},
			TeamB: [2]string{prefix + "3", prefix + "4"}}},
		PlayedGames:   []string{"0-0"},
		GameScores:    map[string]domain.GameScore{"0-0": {A: 21, B: 10}},
		AbsentPlayers: absent,
	}
	if _, err := st.Save(ctx, id, snap); err != nil {
		t.Fatalf("save: %v", err)
	}
	saveLock(t, st, ctx, id)
	if r, err := st.IngestSession(ctx, id); err != nil || r.Processed != 1 {
		t.Fatalf("ingest: %+v %v", r, err)
	}
	t.Cleanup(func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (
			SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE $1)`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE $1`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE $1`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.sessions SET status='draft' WHERE share_code LIKE $1`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.scheduled_game_players WHERE scheduled_game_internal_id IN (
			SELECT sg.internal_id FROM `+schema+`.scheduled_games sg
			JOIN `+schema+`.sessions s ON s.id = sg.session_id WHERE s.share_code LIKE $1)`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.scheduled_games WHERE session_id IN (
			SELECT id FROM `+schema+`.sessions WHERE share_code LIKE $1)`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.session_players WHERE session_id IN (
			SELECT id FROM `+schema+`.sessions WHERE share_code LIKE $1)`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE $1`, prefix+"%")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (
			SELECT id FROM `+schema+`.players WHERE canonical_name LIKE $1)`, prefix+" %")
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE $1`, prefix+" %")
	})
	return ctx, date
}

// TestIntegrationRebuildJourneyGate — pemain journey-gagal (registered_at >
// tanggal sesi) tanpa delta: rekonstruksi TIDAK boleh menambahkan delta yang
// sudah ditolak ingest.
func TestIntegrationRebuildJourneyGate(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx, date := rbjFixture(t, st, schema, "RB Journey", nil)

	pid := resolveIDByAlias(t, st, "rb journey one")
	if n := countPlayerDeltas(t, st, schema, pid); n != 1 {
		t.Fatalf("setelah ingest delta RB Journey One = %d, want 1", n)
	}

	// registered_at geser ke SETELAH tanggal sesi → journey gagal.
	// Delta dihapus: ini kondisi yang ditinggalkan ingest (menolak pemain ini).
	if _, err := st.pool.Exec(ctx, `
		UPDATE `+schema+`.players SET registered_at = $2::date + 10 WHERE id = $1::uuid`,
		pid, date); err != nil {
		t.Fatalf("geser registered_at: %v", err)
	}
	if _, err := st.pool.Exec(ctx,
		`DELETE FROM `+schema+`.rating_deltas WHERE player_id = $1::uuid`, pid); err != nil {
		t.Fatalf("hapus delta: %v", err)
	}

	if _, err := st.RebuildAll(ctx); err != nil {
		t.Fatalf("rebuild: %v", err)
	}
	if n := countPlayerDeltas(t, st, schema, pid); n != 0 {
		t.Fatalf("rebuild menambah delta journey-gagal: %d, want 0", n)
	}
	// Pemain journey-nya lolos tetap dinilai.
	pid2 := resolveIDByAlias(t, st, "rb journey two")
	if n := countPlayerDeltas(t, st, schema, pid2); n != 1 {
		t.Fatalf("RB Journey Two delta = %d, want 1", n)
	}
}

// TestIntegrationRebuildKeepsRecordedDeltas — kasus prod "Zaki": registered_at
// berubah SETELAH delta diberikan. Delta yang tercatat harus TETAP dipertahankan
// rebuild (rating_deltas = catatan yang menang per event+pemain) — kalau
// rekonstruksi menang mutlak, 6 delta Zaki di prod akan musnah saat rebuild.
func TestIntegrationRebuildKeepsRecordedDeltas(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx, date := rbjFixture(t, st, schema, "RB Record", nil)

	pid := resolveIDByAlias(t, st, "rb record one")
	if n := countPlayerDeltas(t, st, schema, pid); n != 1 {
		t.Fatalf("setelah ingest delta = %d, want 1", n)
	}
	// registered_at digeser belakangan — delta TIDAK dihapus (catatan tetap).
	if _, err := st.pool.Exec(ctx, `
		UPDATE `+schema+`.players SET registered_at = $2::date + 10 WHERE id = $1::uuid`,
		pid, date); err != nil {
		t.Fatalf("geser registered_at: %v", err)
	}

	if _, err := st.RebuildAll(ctx); err != nil {
		t.Fatalf("rebuild: %v", err)
	}
	if n := countPlayerDeltas(t, st, schema, pid); n != 1 {
		t.Fatalf("delta tercatat hilang setelah rebuild: %d, want 1 (registered_at berubah belakangan tidak boleh membatalkan catatan)", n)
	}
}

// TestIntegrationRebuildHonorsAbsentCountPolicy — absent_policy=count: pemain
// absent dihitung normal (dapat delta di ingest). Rebuild harus menilainya
// sama; tanpa dukungan count ia kehilangan delta-nya.
func TestIntegrationRebuildHonorsAbsentCountPolicy(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()
	t.Cleanup(func() {
		_, _ = st.pool.Exec(ctx,
			`UPDATE `+schema+`.rating_config SET value='"skip_player"' WHERE key='absent_policy'`)
	})
	if _, err := st.pool.Exec(ctx,
		`UPDATE `+schema+`.rating_config SET value='"count"' WHERE key='absent_policy'`); err != nil {
		t.Fatalf("set absent_policy=count: %v", err)
	}

	_, _ = rbjFixture(t, st, schema, "RB Count", []string{"RB Count4"})

	pid := resolveIDByAlias(t, st, "rb count four")
	if n := countPlayerDeltas(t, st, schema, pid); n != 1 {
		t.Fatalf("setelah ingest (count) delta pemain absent = %d, want 1", n)
	}
	// Delta dihapus: pemulihan penuh harus lewat rekonstruksi — di situlah
	// keputusan absent_policy diambil (baris deltas lama menyembunyikan
	// perbedaan karena ia selalu menandai pemain sebagai hadir).
	if _, err := st.pool.Exec(ctx,
		`DELETE FROM `+schema+`.rating_deltas WHERE player_id = $1::uuid`, pid); err != nil {
		t.Fatalf("hapus delta: %v", err)
	}
	if _, err := st.RebuildAll(ctx); err != nil {
		t.Fatalf("rebuild: %v", err)
	}
	if n := countPlayerDeltas(t, st, schema, pid); n != 1 {
		t.Fatalf("rebuild (count) delta pemain absent = %d, want 1 — rekonstruksi harus menilai pemain absent saat policy=count", n)
	}
}
