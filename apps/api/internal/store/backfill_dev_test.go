package store

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"testing"
	"time"

	"majadu-api/internal/db"
)

// TestBackfillDev — P3: backfill SEMUA source dari bm_dev ke rating engine,
// urut kronologis. LOCKED/expired session diingest; draft hari ini dilewati;
// tournament di-finalize dulu lalu diingest. Idempotent (fingerprint).
//
// Hanya jalan dengan MAJADU_TEST_DATABASE_URL (SSH tunnel):
//
//	MAJADU_TEST_DATABASE_URL="postgres://majadu_app:...@localhost:15432/bm_dev" \
//	MAJADU_TEST_DB_SCHEMA=bm_dev go test ./internal/store/ -run TestBackfillDev -v
func TestBackfillDev(t *testing.T) {
	url := os.Getenv("MAJADU_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("MAJADU_TEST_DATABASE_URL not set")
	}
	schema := os.Getenv("MAJADU_TEST_DB_SCHEMA")
	if schema == "" {
		schema = "bm_dev"
	}
	pool, err := db.NewPool(context.Background(), url, schema, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatalf("db connect: %v", err)
	}
	defer pool.Close()
	st := NewSessionStore(pool, schema)
	ctx := context.Background()

	// 1. Auto-lock sesi expired (gate final)
	n, err := st.AutoLockExpiredSessions(ctx)
	if err != nil {
		t.Fatalf("auto-lock: %v", err)
	}
	t.Logf("auto-lock: %d sesi expired di-lock", n)

	// 2. Daftar SEMUA source (sesi + tournament) urut kronologis — seq
	// invariant mengharuskan urutan tanggal (tournament lama harus duluan).
	rows, err := pool.Query(ctx, `
		SELECT 'session', share_code, session_date::text, status
		FROM `+schema+`.sessions
		UNION ALL
		SELECT 'tournament', share_code, event_date::text, format
		FROM `+schema+`.tournaments
		ORDER BY 3 ASC, 1 ASC, 2 ASC`)
	if err != nil {
		t.Fatalf("list sources: %v", err)
	}
	type sRow struct {
		kind, id, date, status string
	}
	sources := []sRow{}
	for rows.Next() {
		var r sRow
		if err := rows.Scan(&r.kind, &r.id, &r.date, &r.status); err != nil {
			rows.Close()
			t.Fatal(err)
		}
		sources = append(sources, r)
	}
	rows.Close()

	ingested, skipped := 0, 0
	for _, s := range sources {
		// Lewati sesi test integration (it-rating*) — bukan data riil
		if len(s.id) >= 9 && s.id[:9] == "it-rating" {
			continue
		}
		var res *IngestResult
		var err error
		if s.kind == "session" {
			res, err = st.IngestSession(ctx, s.id)
		} else {
			if err := st.SetSourceFinalized(ctx, s.id, true); err != nil {
				t.Fatalf("finalize %s: %v", s.id, err)
			}
			res, err = st.IngestTournament(ctx, s.id)
		}
		if errors.Is(err, ErrSourceNotFinal) {
			t.Logf("  skip (draft): %s %s (%s) — %s", s.kind, s.id, s.date, s.status)
			skipped++
			continue
		}
		if err != nil {
			t.Logf("  gagal: %s %s (%s): %v", s.kind, s.id, s.date, err)
			skipped++
			continue
		}
		t.Logf("  %s %s (%s): processed=%d skipped=%d players=%d",
			s.kind, s.id, s.date, res.Processed, len(res.Skipped), res.Players)
		ingested++
	}
	t.Logf("sources: %d diingest, %d skip/gagal", ingested, skipped)

	// 4. Ringkasan akhir
	var ev, pl int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.rating_events`).Scan(&ev); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.rating_players WHERE games_played > 0`).Scan(&pl); err != nil {
		t.Fatal(err)
	}
	t.Logf("HASIL: %d events, %d pemain aktif ter-rating", ev, pl)
	_ = time.Now
	_ = fmt.Sprintf
}
