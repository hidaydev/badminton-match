package store

// Verifikasi bug #1 (leaderboard miscount): dengan absent_policy=skip_player,
// game yang memuat pemain absent HARUS tetap dihitung untuk 3 pemain lain
// (hanya pemain absent yang tidak dapat delta).
//
// Jalan: MAJADU_TEST_DATABASE_URL=postgres://majadu_app:...@localhost:15432/bm_dev \
//        MAJADU_TEST_DB_SCHEMA=bm_dev go test ./internal/store/ -run TestVerifyAbsentSkipPlayer -v

import (
	"context"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"

	"majadu-api/internal/db"
)

func TestVerifyAbsentSkipPlayer(t *testing.T) {
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

	// 1. Set absent_policy = skip_player (kontrak produk)
	if _, err := pool.Exec(ctx, `UPDATE `+schema+`.rating_config SET value='"skip_player"' WHERE key='absent_policy'`); err != nil {
		t.Fatalf("set absent_policy: %v", err)
	}

	// 2. Full revert semua source (events dihapus + rebuild)
	rows, err := pool.Query(ctx, `SELECT DISTINCT source_id FROM `+schema+`.rating_events`)
	if err != nil {
		t.Fatalf("list sources: %v", err)
	}
	sources := []string{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			t.Fatal(err)
		}
		sources = append(sources, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	for _, id := range sources {
		if strings.HasPrefix(id, "it-") {
			continue
		}
		if _, err := st.RevertSource(ctx, id, "session"); err != nil {
			t.Logf("revert %s: %v", id, err)
		}
	}

	// 3. Re-ingest kronologis
	order, err := pool.Query(ctx, `
		SELECT share_code FROM `+schema+`.sessions
		WHERE session_date >= (SELECT (value #>> '{}')::date FROM `+schema+`.rating_config WHERE key='season_start')
		  AND status != 'draft'
		ORDER BY session_date ASC, created_at ASC`)
	if err != nil {
		t.Fatalf("order: %v", err)
	}
	ids := []string{}
	for order.Next() {
		var id string
		if err := order.Scan(&id); err != nil {
			order.Close()
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	order.Close()
	for _, id := range ids {
		if strings.HasPrefix(id, "it-") {
			continue
		}
		if _, err := st.IngestSession(ctx, id); err != nil {
			t.Logf("ingest %s: %v", id, err)
		}
	}

	// 4. Verifikasi Beby di sesi 6tzmzz: 3 scored game → 3 events (bukan 2)
	var byPid string
	if err := pool.QueryRow(ctx, `SELECT id::text FROM `+schema+`.players WHERE canonical_name='Beby'`).Scan(&byPid); err != nil {
		t.Fatalf("find Beby: %v", err)
	}
	var byGames int
	if err := pool.QueryRow(ctx, `
		SELECT count(*) FROM `+schema+`.rating_events re
		JOIN `+schema+`.rating_deltas rd ON rd.event_id = re.id
		WHERE re.source_id = '6tzmzz' AND rd.player_id = $1::uuid`, byPid).Scan(&byGames); err != nil {
		t.Fatalf("count Beby events: %v", err)
	}
	t.Logf("Beby di 6tzmzz: %d events (harusnya 3)", byGames)
	if byGames != 3 {
		t.Fatalf("BUG: Beby harus 3 game, dapat %d", byGames)
	}

	// 5. Verifikasi Zainal (absent) TIDAK dapat delta dari game absent-nya
	var zaPid string
	if err := pool.QueryRow(ctx, `SELECT id::text FROM `+schema+`.players WHERE canonical_name='Zainal'`).Scan(&zaPid); err != nil {
		t.Fatalf("find Zainal: %v", err)
	}
	var zaGames int
	if err := pool.QueryRow(ctx, `
		SELECT count(*) FROM `+schema+`.rating_events re
		JOIN `+schema+`.rating_deltas rd ON rd.event_id = re.id
		WHERE re.source_id = '6tzmzz' AND rd.player_id = $1::uuid`, zaPid).Scan(&zaGames); err != nil {
		t.Fatalf("count Zainal events: %v", err)
	}
	t.Logf("Zainal (absent) di 6tzmzz: %d events (game absent tidak boleh masuk)", zaGames)
	if zaGames != 0 {
		t.Fatalf("BUG: Zainal absent dapat delta %d game", zaGames)
	}

	// 6. Total events 6tzmzz harus 21 (18 lama + 3 game absent yang tadinya void)
	var total int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.rating_events WHERE source_id='6tzmzz'`).Scan(&total); err != nil {
		t.Fatal(err)
	}
	t.Logf("events 6tzmzz total: %d (sebelumnya 18, harusnya 21)", total)
	if total != 21 {
		t.Fatalf("BUG: 6tzmzz harus 21 events, dapat %d", total)
	}
}
