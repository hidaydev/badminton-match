package store

import (
	"context"
	"errors"
	"fmt"

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
func (s *SessionStore) ReplayAll(ctx context.Context) (*ReplayReport, error) {
	sources, err := s.listReplaySources(ctx)
	if err != nil {
		return nil, err
	}

	report := &ReplayReport{Results: []ReplayResult{}}
	for _, src := range sources {
		res, err := s.replaySource(ctx, src.id, src.kind)
		if err != nil {
			// Satu sumber gagal tidak memblokir sisanya — laporkan alasannya.
			if s.logger != nil {
				s.logger.Warn("replay-all: sumber dilewati", "source", src.id, "kind", src.kind, "error", err)
			}
			report.Failed++
			report.Results = append(report.Results, ReplayResult{
				SourceID: src.id, Kind: src.kind, Skipped: err.Error(),
			})
			continue
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
	id   string
	kind string
}

// listReplaySources — semua sumber yang layak di-replay, urut kronologis.
// Termasuk yang sudah ter-ingest (fingerprint != ”) — justru itulah kasus
// yang tidak tertangani ticker.
func (s *SessionStore) listReplaySources(ctx context.Context) ([]replaySource, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT share_code, 'session' FROM `+s.schema+`.sessions s
		WHERE s.status != 'draft'
		  AND s.session_date >= (SELECT (value #>> '{}')::date FROM `+s.schema+`.rating_config WHERE key = 'season_start')
		  AND EXISTS (SELECT 1 FROM `+s.schema+`.scheduled_games sg WHERE sg.session_id = s.id)
		  AND COALESCE((SELECT rs.fingerprint FROM `+s.schema+`.rating_sources rs WHERE rs.source_id = s.share_code), '') != ''
		UNION ALL
		SELECT t.share_code,
		       CASE WHEN t.format = 'team' THEN 'tournament_team' ELSE 'tournament_classic' END
		FROM `+s.schema+`.tournaments t
		WHERE t.event_date >= (SELECT (value #>> '{}')::date FROM `+s.schema+`.rating_config WHERE key = 'season_start')
		  AND COALESCE((SELECT rs.fingerprint FROM `+s.schema+`.rating_sources rs WHERE rs.source_id = t.share_code), '') != ''
		  AND (
			(t.format IS DISTINCT FROM 'team' AND EXISTS (
				SELECT 1 FROM `+s.schema+`.tournament_matches tm WHERE tm.tournament_id = t.id))
			OR
			(t.format = 'team' AND EXISTS (
				SELECT 1 FROM `+s.schema+`.tournament_team_match_games g
				JOIN `+s.schema+`.tournament_team_matches m ON m.id = g.team_match_id
				WHERE m.tournament_id = t.id))
		  )
		ORDER BY 1`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []replaySource{}
	for rows.Next() {
		var r replaySource
		if err := rows.Scan(&r.id, &r.kind); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// replaySource — hapus events sumber (bila ada) lalu ingest ulang.
//
// Fingerprint dikosongkan lebih dulu supaya ingest memperlakukan ini sebagai
// ingest baru (bukan ErrSourceChanged). Tanpa itu, AutoReconcile=false akan
// menolak sumber yang memang sengaja kita proses ulang.
func (s *SessionStore) replaySource(ctx context.Context, sourceID, kind string) (*IngestResult, error) {
	tx, err := s.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 0))`,
		s.schema+":ratings_ingest"); err != nil {
		return nil, err
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

	// Ingest di transaksi terpisah (ingest punya tx + lock sendiri).
	if kind == "session" {
		return s.IngestSession(ctx, sourceID)
	}
	// Turnamen: finalisasi dulu (gate extractTournamentMatches).
	if err := s.SetSourceFinalized(ctx, sourceID, true); err != nil {
		return nil, err
	}
	return s.IngestTournament(ctx, sourceID)
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
