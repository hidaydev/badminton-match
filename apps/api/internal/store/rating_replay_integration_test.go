package store

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"majadu-api/internal/domain"
)

// TestIntegrationReplayAll — ReplayAll memperbaiki sumber yang sudah
// ter-ingest lalu berubah.
//
// Kasus yang diuji adalah gap yang TIDAK tertangani ticker:
// AutoIngestLockedSessions hanya menyapu sumber dengan fingerprint = ”
// (belum pernah di-ingest). Sumber yang sudah ter-ingest lalu skornya diedit
// mengembalikan ErrSourceChanged dan dibiarkan basi selamanya.
func TestIntegrationReplayAll(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	const prefix = "it-replay"
	players := []domain.Player{
		{ID: "rpl1", Name: "RPL One", Gender: "M", Tier: 3}, // C → mid 1450
		{ID: "rpl2", Name: "RPL Two", Gender: "M", Tier: 3},
		{ID: "rpl3", Name: "RPL Three", Gender: "M", Tier: 1}, // D → mid 1150
		{ID: "rpl4", Name: "RPL Four", Gender: "M", Tier: 1},
	}
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (
			SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE 'it-replay%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE 'it-replay%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE 'it-replay%'`)
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.sessions SET status='draft' WHERE share_code LIKE 'it-replay%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE 'it-replay%'`)
		// Pemain dihapus TOTAL, bukan hanya rating-nya: Save menulis
		// players.registered_at = tanggal sesi, dan gate journey
		// (m.Date >= registered_at) memakai nilai itu. Run sebelumnya yang
		// bertanggal lebih jauh akan meninggalkan registered_at di masa depan
		// sehingga semua game jadi "no eligible players" di run berikutnya.
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'rpl %'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'RPL %'`)
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

	snap := func(scoreA, scoreB int) *domain.CloudSnapshot {
		return &domain.CloudSnapshot{
			Session: domain.SessionConfig{
				Title: "RPL", Date: date, Courts: 1,
				SessionStart: "09:00", SlotMinutes: 20,
				CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
				PlayerCount: 4, CourtNames: []string{"C1"},
			},
			Players: players, FixMatches: []domain.FixMatch{},
			Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"rpl1", "rpl2"}, TeamB: [2]string{"rpl3", "rpl4"}}},
			PlayedGames: []string{"0-0"},
			GameScores:  map[string]domain.GameScore{"0-0": {A: scoreA, B: scoreB}},
		}
	}

	id := prefix + "-1"
	if _, err := st.Save(ctx, id, snap(21, 10)); err != nil {
		t.Fatalf("save: %v", err)
	}
	saveLock(t, st, ctx, id)
	if r, err := st.IngestSession(ctx, id); err != nil || r.Processed != 1 {
		t.Fatalf("ingest awal: res=%+v err=%v", r, err)
	}

	// Skor diedit SETELAH ingest (sesi sudah ter-lock).
	// Save harus diizinkan untuk sesi locked via jalur admin; kalau tidak,
	// ubah langsung di DB seperti yang terjadi pada kasus nyata.
	if _, err := st.pool.Exec(ctx, `
		UPDATE `+schema+`.scheduled_games SET score_a = 5, score_b = 21
		WHERE session_id = (SELECT id FROM `+schema+`.sessions WHERE share_code = $1)`, id); err != nil {
		t.Fatalf("edit skor: %v", err)
	}

	// Ingest ulang langsung → HARUS ditolak ErrSourceChanged (AutoReconcile=false).
	if _, err := st.IngestSession(ctx, id); err == nil {
		t.Fatal("ingest ulang setelah edit seharusnya ErrSourceChanged (auto_reconcile=false)")
	} else if !errors.Is(err, ErrSourceChanged) {
		t.Fatalf("ingest ulang: err=%v, want ErrSourceChanged", err)
	}

	// Ticker juga tidak memperbaikinya: sesi ini fingerprint-nya sudah terisi,
	// sehingga tidak masuk kandidat AutoIngestLockedSessions (yang hanya
	// menyapu fingerprint = ''). Sesi uji lain di DB tidak relevan di sini.
	var fpAfter string
	if err := st.pool.QueryRow(ctx,
		`SELECT COALESCE(fingerprint,'') FROM `+schema+`.rating_sources WHERE source_id = $1`, id).Scan(&fpAfter); err != nil {
		t.Fatalf("fingerprint: %v", err)
	}
	if fpAfter == "" {
		t.Fatal("sesi replay fingerprint-nya kosong — ticker seharusnya menyapanya, jadi kasus ini bukan yang diuji")
	}
	if _, err := st.AutoIngestLockedSessions(ctx); err != nil {
		t.Fatalf("auto-ingest: %v", err)
	}
	// Sesi replay harus tetap belum diperbaiki ticker (state lama masih terpasang
	// sampai ReplayAll dipanggil di bawah).
	var fpStill string
	if err := st.pool.QueryRow(ctx,
		`SELECT COALESCE(fingerprint,'') FROM `+schema+`.rating_sources WHERE source_id = $1`, id).Scan(&fpStill); err != nil {
		t.Fatalf("fingerprint kedua: %v", err)
	}
	if fpStill != fpAfter {
		t.Fatal("ticker menyentuh sesi replay — seharusnya hanya menyapu fingerprint = ''")
	}

	// ReplayAll → inilah jalur pemulihannya.
	report, err := st.ReplayAll(ctx)
	if err != nil {
		t.Fatalf("replay-all: %v", err)
	}
	found := false
	for _, r := range report.Results {
		if r.SourceID == id {
			found = true
			if r.Skipped != "" {
				t.Fatalf("replay sumber %s dilewati: %s", id, r.Skipped)
			}
		}
	}
	if !found {
		t.Fatalf("replay-all tidak menyentuh sumber %s (results=%+v)", id, report.Results)
	}
	if report.Failed != 0 {
		t.Fatalf("replay-all gagal %d sumber: %+v", report.Failed, report.Results)
	}

	// Skor baru (kalah) harus tercermin: RPL One sempat menang 21-10,
	// sekarang kalah 5-21, jadi rating/presentasinya berubah.
	pid := resolveIDByAlias(t, st, "rpl one")
	after, err := st.RatingPlayer(ctx, pid)
	if err != nil || after == nil {
		t.Fatalf("detail: %v", err)
	}
	if after.Games != 1 {
		t.Fatalf("RPL One games=%d, want 1", after.Games)
	}
	if after.Wins != 0 {
		t.Fatalf("RPL One wins=%d, want 0 setelah skor diedit jadi kalah", after.Wins)
	}

	// Idempotent: replay kedua menghasilkan state yang sama.
	report2, err := st.ReplayAll(ctx)
	if err != nil {
		t.Fatalf("replay kedua: %v", err)
	}
	if report2.Failed != 0 {
		t.Fatalf("replay kedua gagal: %+v", report2.Results)
	}
	again, err := st.RatingPlayer(ctx, pid)
	if err != nil || again == nil {
		t.Fatalf("detail kedua: %v", err)
	}
	if again.Rating != after.Rating || again.Games != after.Games {
		t.Fatalf("replay tidak idempotent: %.4f/%d vs %.4f/%d",
			after.Rating, after.Games, again.Rating, again.Games)
	}
}

// TestIntegrationRebuildAllRefusesWithoutMapping — pengaman data-loss.
//
// rebuildAll menghapus rating_players + rating_deltas lalu menyusun ulang dari
// pemetaan event→pemain yang dibaca lebih dulu: rekonstruksi dari sesi (utama)
// lalu rating_deltas (cadangan).
//
// Kalau KEDUA sumbernya habis — deltas kosong DAN sesinya sudah tidak ada —
// rebuild akan menulis seluruh rating sebagai kosong TANPA jalur pemulihan.
// Kondisi itu harus DITOLAK, bukan dijalankan.
func TestIntegrationRebuildAllRefusesWithoutMapping(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	const prefix = "it-rbmap"
	players := []domain.Player{
		{ID: "rbm1", Name: "RBM One", Gender: "M", Tier: 3},
		{ID: "rbm2", Name: "RBM Two", Gender: "M", Tier: 3},
		{ID: "rbm3", Name: "RBM Three", Gender: "M", Tier: 1},
		{ID: "rbm4", Name: "RBM Four", Gender: "M", Tier: 1},
	}
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.scheduled_games WHERE session_id IN (SELECT id FROM `+schema+`.sessions WHERE share_code LIKE '`+prefix+`%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'RBM %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'rbm %'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'RBM %'`)
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
		t.Fatalf("tanggal: %v", err)
	}

	id := prefix + "-sess"
	if _, err := st.Save(ctx, id, &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "RBM", Date: date, Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: 4, CourtNames: []string{"C1"},
		},
		Players: players, FixMatches: []domain.FixMatch{},
		Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{"rbm1", "rbm2"}, TeamB: [2]string{"rbm3", "rbm4"}}},
		PlayedGames: []string{"0-0"},
		GameScores:  map[string]domain.GameScore{"0-0": {A: 21, B: 10}},
	}); err != nil {
		t.Fatalf("save: %v", err)
	}
	saveLock(t, st, ctx, id)
	if r, err := st.IngestSession(ctx, id); err != nil || r.Processed != 1 {
		t.Fatalf("ingest: %+v %v", r, err)
	}

	// Simulasi kerusakan TOTAL: rating_deltas hilang DAN sumber kebenaran
	// (sesi) ikut hilang — tidak ada jalur rekonstruksi tersisa.
	//
	// Beda dengan kerusakan parsial (deltas hilang, sesi masih ada): saat itu
	// RebuildAll justru harus BERHASIL memulihkan pemetaan dari sesi — kasus
	// ini diuji TestIntegrationRebuildRestoresMissingDeltas. Pengaman di
	// bawah hanya berlaku kalau KEDUA sumbernya habis.
	if _, err := st.pool.Exec(ctx, `
		DELETE FROM `+schema+`.rating_deltas
		WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE '`+prefix+`%')`); err != nil {
		t.Fatalf("hapus deltas: %v", err)
	}
	if _, err := st.pool.Exec(ctx, `
		DELETE FROM `+schema+`.scheduled_game_players
		WHERE scheduled_game_internal_id IN (
			SELECT sg.internal_id FROM `+schema+`.scheduled_games sg
			JOIN `+schema+`.sessions s ON s.id = sg.session_id
			WHERE s.share_code LIKE '`+prefix+`%')`); err != nil {
		t.Fatalf("hapus pemain game: %v", err)
	}
	if _, err := st.pool.Exec(ctx, `
		DELETE FROM `+schema+`.scheduled_games
		WHERE session_id IN (SELECT id FROM `+schema+`.sessions WHERE share_code LIKE '`+prefix+`%')`); err != nil {
		t.Fatalf("hapus scheduled_games: %v", err)
	}
	if _, err := st.pool.Exec(ctx, `
		DELETE FROM `+schema+`.sessions WHERE share_code LIKE '`+prefix+`%'`); err != nil {
		t.Fatalf("hapus sesi: %v", err)
	}

	// Jangan biarkan test lain (yang mungkin gagal) memusnahkan rating nyata:
	// hitung dulu berapa baris rating_players sebelum rebuild gagal.
	var before int
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.rating_players`).Scan(&before); err != nil {
		t.Fatalf("hitung rating_players: %v", err)
	}

	if _, err := st.RebuildAll(ctx); err == nil {
		t.Fatal("RebuildAll harus MENOLAK saat pemetaan event→pemain kosong")
	} else {
		t.Logf("ditolak seperti diharapkan: %v", err)
	}

	var after int
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.rating_players`).Scan(&after); err != nil {
		t.Fatalf("hitung rating_players 2: %v", err)
	}
	if after != before {
		t.Errorf("rating_players berubah walau rebuild ditolak: %d → %d", before, after)
	}
}

// TestIntegrationReplayAllMultipleSources — ReplayAll harus memulihkan SEMUA
// sumber, bukan hanya sumber yang kebetulan paling baru.
//
// Bug yang dijaga test ini: replay dulu menghapus events lalu meng-ingest satu
// per satu. Selama masih ada events sumber lain, ingest sumber yang lebih lama
// selalu ditolak invariant ErrOutOfOrder — akibatnya sumber itu gagal DAN
// events-nya sudah terhapus (fingerprint juga sudah dikosongkan, jadi tidak
// pernah terpilih lagi; ticker kena ErrOutOfOrder yang sama). Data hilang
// permanen. Urutan pemrosesan dulu = share_code, yang posisinya terhadap
// tanggal TIDAK menentukannya.
//
// Fixture-nya sengaja dibuat berlawanan: sesi LEBIH LAMA dapat share_code
// yang urut abjadnya DI AWAL ("aa…" = duluan diproses desain lama), dan sesi
// lebih baru di akhir ("zz…"). Desain lama gagal di langkah pertama; desain
// baru (hapus semua dulu → ingest menaik) sukses untuk keduanya.
func TestIntegrationReplayAllMultipleSources(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	// id sesi: urutan abjad sengaja BERLAWANAN dengan tanggal ("aa" = lebih
	// lama) supaya desain lama (urut share_code) gagal deterministik.
	const prefixJul = "aa-rt-jul"
	const prefixAug = "zz-rt-aug"
	mkPlayers := func(prefix string, names []string) []domain.Player {
		out := []domain.Player{}
		for i, n := range names {
			out = append(out, domain.Player{
				ID:     fmt.Sprintf("%s%d", prefix, i+1),
				Name:   n,
				Gender: "M",
				Tier:   3,
			})
		}
		return out
	}
	julPlayers := mkPlayers("rtj", []string{"RTJ One", "RTJ Two", "RTJ Three", "RTJ Four"})
	augPlayers := mkPlayers("rta", []string{"RTA One", "RTA Two", "RTA Three", "RTA Four"})
	// Pemain terpisah per sesi: registered_at (ditulis Save) jangan sampai
	// men-gate sesi yang lebih lama.

	cleanup := func() {
		for _, p := range []string{prefixJul, prefixAug} {
			_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_deltas WHERE event_id IN (SELECT id FROM `+schema+`.rating_events WHERE source_id LIKE '`+p+`%')`)
			_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE '`+p+`%'`)
			_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE '`+p+`%'`)
			_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.scheduled_games WHERE session_id IN (SELECT id FROM `+schema+`.sessions WHERE share_code LIKE '`+p+`%')`)
			_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE '`+p+`%'`)
		}
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'RTJ %' OR canonical_name LIKE 'RTA %')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'rtj %' OR alias_name LIKE 'rta %'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'RTJ %' OR canonical_name LIKE 'RTA %'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	if err := st.EnsurePlayersRegistered(ctx, append(append([]domain.Player{}, julPlayers...), augPlayers...)); err != nil {
		t.Fatalf("register: %v", err)
	}

	// Dua tanggal: jul = setelah event terakhir, aug = sehari sesudahnya.
	var dateJul, dateAug string
	if err := st.pool.QueryRow(ctx, `
		SELECT (GREATEST(
			(SELECT (value #>> '{}')::date FROM `+schema+`.rating_config WHERE key='season_start'),
			COALESCE((SELECT max(date) FROM `+schema+`.rating_events), CURRENT_DATE)
		) + INTERVAL '1 day')::date::text,
		(GREATEST(
			(SELECT (value #>> '{}')::date FROM `+schema+`.rating_config WHERE key='season_start'),
			COALESCE((SELECT max(date) FROM `+schema+`.rating_events), CURRENT_DATE)
		) + INTERVAL '2 day')::date::text`).Scan(&dateJul, &dateAug); err != nil {
		t.Fatalf("tanggal: %v", err)
	}

	saveOne := func(id, title, date string, players []domain.Player, teamA, teamB [2]string) {
		t.Helper()
		snap := &domain.CloudSnapshot{
			Session: domain.SessionConfig{
				Title: title, Date: date, Courts: 1,
				SessionStart: "09:00", SlotMinutes: 20,
				CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
				PlayerCount: 4, CourtNames: []string{"C1"},
			},
			Players: players, FixMatches: []domain.FixMatch{},
			Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: teamA, TeamB: teamB}},
			PlayedGames: []string{"0-0"},
			GameScores:  map[string]domain.GameScore{"0-0": {A: 21, B: 10}},
		}
		if _, err := st.Save(ctx, id, snap); err != nil {
			t.Fatalf("save %s: %v", id, err)
		}
		saveLock(t, st, ctx, id)
		if r, err := st.IngestSession(ctx, id); err != nil || r.Processed != 1 {
			t.Fatalf("ingest %s: %+v %v", id, r, err)
		}
	}

	idJul, idAug := prefixJul, prefixAug
	saveOne(idJul, "RT Jul", dateJul, julPlayers,
		[2]string{"rtj1", "rtj2"}, [2]string{"rtj3", "rtj4"})
	saveOne(idAug, "RT Aug", dateAug, augPlayers,
		[2]string{"rta1", "rta2"}, [2]string{"rta3", "rta4"})

	countEvents := func(id string) int {
		t.Helper()
		var n int
		if err := st.pool.QueryRow(ctx,
			`SELECT count(*) FROM `+schema+`.rating_events WHERE source_id = $1`, id).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if countEvents(idJul) != 1 || countEvents(idAug) != 1 {
		t.Fatalf("prasyarat: jul=%d aug=%d events, want 1+1", countEvents(idJul), countEvents(idAug))
	}

	report, err := st.ReplayAll(ctx)
	if err != nil {
		t.Fatalf("replay-all: %v", err)
	}
	t.Logf("replay-all: replayed=%d failed=%d", report.Replayed, report.Failed)
	for _, r := range report.Results {
		t.Logf("  %s (%s): processed=%d skipped=%q", r.SourceID, r.Kind, r.Processed, r.Skipped)
	}

	if report.Failed != 0 {
		t.Errorf("failed=%d, want 0 — sumber kehilangan events tanpa bisa dipulihkan", report.Failed)
	}
	// Kedua sumber harus ter-ingest ulang, events-nya utuh.
	if n := countEvents(idJul); n != 1 {
		t.Errorf("events %s = %d, want 1 (hilang setelah replay)", idJul, n)
	}
	if n := countEvents(idAug); n != 1 {
		t.Errorf("events %s = %d, want 1 (hilang setelah replay)", idAug, n)
	}
	// Fingerprint kembali terisi (artinya benar-benar di-ingest, bukan dilewati).
	for _, id := range []string{idJul, idAug} {
		var fp string
		if err := st.pool.QueryRow(ctx,
			`SELECT coalesce(fingerprint,'') FROM `+schema+`.rating_sources WHERE source_id = $1`, id).Scan(&fp); err != nil {
			t.Fatalf("baca fingerprint %s: %v", id, err)
		}
		if fp == "" {
			t.Errorf("%s: fingerprint kosong — sumber tidak di-ingest ulang", id)
		}
	}
}
