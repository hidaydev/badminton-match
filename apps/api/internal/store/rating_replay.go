package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
)

// ReplayResult — ringkasan satu sumber yang diproses ulang.
type ReplayResult struct {
	SourceID  string `json:"source_id"`
	Kind      string `json:"kind"` // session | tournament_classic | tournament_team
	Processed int    `json:"processed"`
	Skipped   string `json:"skipped,omitempty"` // alasan bila tidak diproses
}

// ReplayReport — ringkasan keseluruhan replay-all.
type ReplayReport struct {
	Replayed int            `json:"replayed"` // sumber yang berhasil di-ingest ulang
	Failed   int            `json:"failed"`   // sumber yang gagal (lihat Results)
	Rebuilt  int            `json:"rebuilt"`  // jumlah pemain dari RebuildAll terakhir
	Results  []ReplayResult `json:"results"`
}

// ReplayAll — proses ulang SEMUA sumber rating (sesi non-draft + turnamen
// selesai) sejak season_start, lalu RebuildAll sekali di akhir.
//
// Kapan dipakai: ticker (AutoIngestLockedSessions) hanya menyapu sumber yang
// BELUM pernah di-ingest (fingerprint = ”). Sumber yang sudah ter-ingest lalu
// berubah — skor diedit setelah sesi ter-lock, atau sesi yang ter-lock telat
// sementara skornya sudah final — mengembalikan ErrSourceChanged (409) dan
// TIDAK pernah diperbaiki otomatis. Akibatnya rating diam-diam basi.
// Endpoint ini jalur pemulihan eksplisitnya (naikkan auto_reconcile atau
// panggil ini dari admin).
//
// Berbeda dari memanggil RevertSource per sumber: rebuild hanya dilakukan
// SEKALI di akhir, bukan sekali per sumber — jadi biayanya O(events), bukan
// O(events × jumlah sumber).
//
// PENTING — urutan operasi: events SEMUA sumber dihapus dahulu (satu
// transaksi), baru ingest satu per satu URUT NAIK (date, created_at,
// source_id). Desain "hapus + ingest per sumber bergantian" tidak mungkin
// bekerja: selama masih ada events sumber lain, ingest sumber yang lebih lama
// selalu ditolak invariant ErrOutOfOrder (batch harus lebih baru dari max
// yang tersisa), sehingga sumber-sumber itu gagal dan events-nya sudah
// terhapus — hilang permanen (ticker pun kena ErrOutOfOrder yang sama, karena
// tanggalnya memang lebih lama dari sisa). Dengan menghapus dulu semuanya,
// tiap ingest menghadapi max yang lebih lama darinya sendiri → selalu lolos.
//
// Bila ingest sumber GAGAL, loop BERHENTI (break) — sumber lebih baru sengaja
// tidak diproses. Meng-ingest yang lebih baru membuat sumber gagal terkunci
// permanen: invariant ErrOutOfOrder menolak batch yang lebih lama, dan ticker
// (AutoIngestLockedSessions, AutoIngestTournaments) memilih fingerprint = ”
// tapi tetap kena ErrOutOfOrder yang sama. Sumber yang belum diproses
// ber-events kosong + fingerprint = ”: kalau errornya transient, ticker
// memulihkannya urut menaik pada run berikutnya; kalau permanen — perbaiki
// datanya lalu jalankan ulang replay-all (idempoten: clear semua → ingest
// urut → RebuildAll sekali).
//
// Crash di tengah loop (proses mati) pulih dengan cara yang sama: re-run
// replay-all. Clear-all membuang events parsial, lalu ingest ulang bersih +
// RebuildAll mengoreksi rating_players — ingest di atas state lama tanpa
// RebuildAll bisa menumpuk delta ganda di atas kontribusi lama.
//
// Catatan batas: clear-all dan loop ingest adalah transaksi TERPISAH; ticker
// yang jalan di antaranya bisa meng-ingest sumber ber-fingerprint = ” lebih
// dahulu. Bila report.ReplayAll mengembalikan kegagalan ErrOutOfOrder,
// jalankan ulang replay-all.
func (s *SessionStore) ReplayAll(ctx context.Context) (*ReplayReport, error) {
	sources, err := s.listReplaySources(ctx)
	if err != nil {
		return nil, err
	}

	report := &ReplayReport{Results: []ReplayResult{}}
	if len(sources) > 0 {
		if err := s.clearSources(ctx, sources); err != nil {
			return nil, err
		}
	}

	for _, src := range sources {
		res, err := s.ingestClearedSource(ctx, src.id, src.kind)
		if err != nil {
			// BERHENTI di kegagalan pertama. Lanjut ke sumber lebih baru
			// = menanam max event baru sehingga sumber ini (dan semua yang
			// lebih lama) gagal ErrOutOfOrder selamanya — termasuk di mata
			// ticker. Sisa sumber belum diproses; lihat catatan urutan di
			// atas untuk jalur pemulihannya.
			if s.logger != nil {
				s.logger.Warn("replay-all: berhenti pada sumber gagal", "source", src.id, "kind", src.kind, "error", err)
			}
			report.Failed++
			report.Results = append(report.Results, ReplayResult{
				SourceID: src.id, Kind: src.kind, Skipped: err.Error(),
			})
			break
		}
		report.Replayed++
		report.Results = append(report.Results, ReplayResult{
			SourceID: src.id, Kind: src.kind, Processed: res.Processed,
		})
	}

	// Satu rebuild untuk semua — state akhir harus konsisten.
	rebuilt, err := s.RebuildAll(ctx)
	if err != nil {
		return nil, err
	}
	report.Rebuilt = rebuilt
	return report, nil
}

type replaySource struct {
	id        string
	kind      string
	date      string
	createdAt time.Time
}

// listReplaySources — semua sumber yang layak di-replay, URUT NAIK kronologis
// (date, created_at, source_id) — kunci invariant ErrOutOfOrder di ingest.
//
// Filter fingerprint DIHAPUS: dulu hanya sumber ber-fingerprint terisi yang
// terpilih, sehingga sumber yang baru di-clear (fingerprint = ”) — persis
// kondisi setelah replay-all gagal di tengah — TIDAK BISA di-replay ulang,
// padahal re-run replay-all adalah jalur pemulihannya. Kini sumber
// terdampar/fingerprint ” ikut terpilih; ticker memilihnya juga, tapi
// pemilihan ulang lewat replay-all aman (clear semua dulu, lalu ingest urut).
func (s *SessionStore) listReplaySources(ctx context.Context) ([]replaySource, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT share_code, 'session', s.session_date::text, s.created_at FROM `+s.schema+`.sessions s
		WHERE s.status != 'draft'
		  AND s.session_date >= (SELECT (value #>> '{}')::date FROM `+s.schema+`.rating_config WHERE key = 'season_start')
		  AND EXISTS (SELECT 1 FROM `+s.schema+`.scheduled_games sg WHERE sg.session_id = s.id)
		UNION ALL
		SELECT t.share_code,
		       CASE WHEN t.format = 'team' THEN 'tournament_team' ELSE 'tournament_classic' END,
		       t.event_date::text, t.created_at
		FROM `+s.schema+`.tournaments t
		WHERE t.event_date >= (SELECT (value #>> '{}')::date FROM `+s.schema+`.rating_config WHERE key = 'season_start')
		  AND (
			(t.format IS DISTINCT FROM 'team' AND EXISTS (
				SELECT 1 FROM `+s.schema+`.tournament_matches tm WHERE tm.tournament_id = t.id))
			OR
			(t.format = 'team' AND EXISTS (
				SELECT 1 FROM `+s.schema+`.tournament_team_match_games g
				JOIN `+s.schema+`.tournament_team_matches m ON m.id = g.team_match_id
				WHERE m.tournament_id = t.id))
		  )
		ORDER BY 3, 4, 1`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []replaySource{}
	for rows.Next() {
		var r replaySource
		if err := rows.Scan(&r.id, &r.kind, &r.date, &r.createdAt); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// clearSources — hapus events + kosongkan fingerprint untuk beberapa sumber
// dalam SATU transaksi (advisory lock dipegang bersama).
//
// Dipisah dari ingest supaya ReplayAll bisa menghapus semua sumber lebih dulu
// sebelum meng-ingest satu pun (lihat catatan urutan di ReplayAll).
func (s *SessionStore) clearSources(ctx context.Context, sources []replaySource) error {
	if len(sources) == 0 {
		return nil
	}
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`,
		s.schema+":ratings_ingest"); err != nil {
		return err
	}
	for _, src := range sources {
		if err := s.deleteSourceEvents(ctx, tx, src.id); err != nil {
			return err
		}
		// Invalidasi fingerprint: ingest berikutnya harus memproses ulang,
		// bukan no-op. Juga yang membuat ticker bersedia memulihkan sumber ini
		// bila ingest selanjutnya gagal (dia memilih fingerprint = ”).
		if _, err := tx.Exec(ctx,
			`UPDATE `+s.schema+`.rating_sources SET fingerprint = '' WHERE source_id = $1`,
			src.id); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// ingestClearedSource — ingest sumber yang events-nya sudah dikosongkan oleh
// clearSources (tanpa menghapus apa pun).
func (s *SessionStore) ingestClearedSource(ctx context.Context, sourceID, kind string) (*IngestResult, error) {
	if kind == "session" {
		return s.IngestSession(ctx, sourceID)
	}
	// Turnamen: finalisasi dulu (gate extractTournamentMatches).
	if err := s.SetSourceFinalized(ctx, sourceID, true); err != nil {
		return nil, err
	}
	return s.IngestTournament(ctx, sourceID)
}

// replaySource — hapus events sumber (bila ada) lalu ingest ulang, SATU
// sumber.
//
// Fingerprint dikosongkan lebih dulu supaya ingest memperlakukan ini sebagai
// ingest baru (bukan ErrSourceChanged). Tanpa itu, AutoReconcile=false akan
// menolak sumber yang memang sengaja kita proses ulang.
//
// Untuk kasus tunggal events sumber lain masih ada, jadi ingest bisa kena
// ErrOutOfOrder. Pre-check di bawah MENOLAK sebelum ada penghapusan — tanpa
// itu events sumber ini hilang permanen setelah ingest ditolak.
func (s *SessionStore) replaySource(ctx context.Context, sourceID, kind string) (*IngestResult, error) {
	// Ambil kunci ordering sumber ini (date, created_at) = basis invariant.
	var srcDate string
	var srcCreated time.Time
	err := s.pool.QueryRow(ctx, `
		SELECT s.session_date::text, s.created_at FROM `+s.schema+`.sessions s WHERE s.share_code = $1
		UNION ALL
		SELECT t.event_date::text, t.created_at FROM `+s.schema+`.tournaments t WHERE t.share_code = $1
		LIMIT 1`, sourceID).Scan(&srcDate, &srcCreated)
	if err != nil {
		return nil, fmt.Errorf("replay: baca tanggal sumber %s: %w", sourceID, err)
	}

	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`,
		s.schema+":ratings_ingest"); err != nil {
		return nil, err
	}

	// Pre-check: ada events sumber LAIN yang lebih baru dari sumber ini?
	// Kalau ya, ingest setelah penghapusan pasti ErrOutOfOrder — menolak di
	// sini menyelamatkan events-nya.
	var outsideNewer bool
	if err := tx.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM `+s.schema+`.rating_events re
			WHERE re.source_id <> $1
			  AND (re.date, re.created_at, re.source_id) > ($2::date, $3::timestamptz, $1::text))`,
		sourceID, srcDate, srcCreated).Scan(&outsideNewer); err != nil {
		return nil, err
	}
	if outsideNewer {
		return nil, fmt.Errorf("%w: source %s (date %s) — events sumber lain lebih baru, hapus/replay sumber yang lebih baru dulu atau pakai replay-all",
			ErrOutOfOrder, sourceID, srcDate)
	}

	if err := s.deleteSourceEvents(ctx, tx, sourceID); err != nil {
		return nil, err
	}
	// Invalidasi fingerprint: ingest berikutnya harus memproses ulang, bukan no-op.
	if _, err := tx.Exec(ctx,
		`UPDATE `+s.schema+`.rating_sources SET fingerprint = '' WHERE source_id = $1`,
		sourceID); err != nil {
		return nil, err
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}

	return s.ingestClearedSource(ctx, sourceID, kind)
}

// ReplaySource — replay satu sumber (dipakai bila admin hanya ingin
// memperbaiki satu sesi/turnamen). Rebuild tetap dilakukan sekali.
func (s *SessionStore) ReplaySource(ctx context.Context, sourceID, kind string) (*ReplayReport, error) {
	if kind != "session" && kind != "tournament" {
		return nil, fmt.Errorf("replay: kind harus 'session' atau 'tournament', dapat %q", kind)
	}
	var exists bool
	err := s.pool.QueryRow(ctx, `
		SELECT EXISTS (
			SELECT 1 FROM `+s.schema+`.sessions WHERE share_code = $1
			UNION ALL
			SELECT 1 FROM `+s.schema+`.tournaments WHERE share_code = $1)`, sourceID).Scan(&exists)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	if !exists {
		return nil, fmt.Errorf("%w: %s", ErrSourceNotFound, sourceID)
	}

	resolvedKind := kind
	if kind == "tournament" {
		var format string
		if err := s.pool.QueryRow(ctx, `SELECT format FROM `+s.schema+`.tournaments WHERE share_code = $1`, sourceID).Scan(&format); err != nil {
			return nil, err
		}
		if format == "team" {
			resolvedKind = "tournament_team"
		} else {
			resolvedKind = "tournament_classic"
		}
	}

	res, err := s.replaySource(ctx, sourceID, resolvedKind)
	report := &ReplayReport{Results: []ReplayResult{}}
	if err != nil {
		report.Failed = 1
		report.Results = append(report.Results, ReplayResult{SourceID: sourceID, Kind: resolvedKind, Skipped: err.Error()})
		return report, nil
	}
	report.Replayed = 1
	report.Results = append(report.Results, ReplayResult{SourceID: sourceID, Kind: resolvedKind, Processed: res.Processed})

	rebuilt, err := s.RebuildAll(ctx)
	if err != nil {
		return nil, err
	}
	report.Rebuilt = rebuilt
	return report, nil
}
