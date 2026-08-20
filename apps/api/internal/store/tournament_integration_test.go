package store

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"reflect"
	"testing"
	"time"

	"majadu-api/internal/db"
	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5/pgxpool"
)

// buildTestTournament — tournament valid: 16 pairs (nama "TPn & TPm"), 4 grup
// penuh, 24 group match + 8 knockout (qf/sf/3rd/final).
func buildTestTournament(name string) *domain.TournamentSnapshot {
	pairs := make([]domain.TournamentPair, 0, 16)
	for i := 0; i < 16; i++ {
		a := fmt.Sprintf("TP%d", i*2+1)
		b := fmt.Sprintf("TP%d", i*2+2)
		pairs = append(pairs, domain.TournamentPair{ID: fmt.Sprintf("p%d", i+1), Name: a + " & " + b})
	}
	groups := map[string][]string{
		"A": {"p1", "p2", "p3", "p4"},
		"B": {"p5", "p6", "p7", "p8"},
		"C": {"p9", "p10", "p11", "p12"},
		"D": {"p13", "p14", "p15", "p16"},
	}
	str := func(s string) *string { return &s }
	matches := []domain.TournamentMatch{}
	// round-robin 6 match per grup (mirror RR di frontend)
	rr := [][2]int{{0, 1}, {2, 3}, {0, 2}, {1, 3}, {0, 3}, {1, 2}}
	for _, g := range []string{"A", "B", "C", "D"} {
		members := groups[g]
		for i, pair := range rr {
			matches = append(matches, domain.TournamentMatch{
				ID:      fmt.Sprintf("group-%s-%d", g, i),
				Phase:   "group",
				GroupID: g,
				PairAID: str(members[pair[0]]),
				PairBID: str(members[pair[1]]),
			})
		}
	}
	// knockout
	koPhases := [][2]string{{"qf-1", "qf"}, {"qf-2", "qf"}, {"qf-3", "qf"}, {"qf-4", "qf"},
		{"sf-1", "sf"}, {"sf-2", "sf"}, {"3rd-1", "3rd"}, {"final-1", "final"}}
	for _, ko := range koPhases {
		matches = append(matches, domain.TournamentMatch{ID: ko[0], Phase: ko[1]})
	}
	return &domain.TournamentSnapshot{Name: name, Date: "2026-08-15", Pairs: pairs, Groups: groups, Matches: matches}
}

// TestIntegrationTournamentParity — verifikasi write/read-path tournament Go
// identik dengan fungsi SQL lama (publish_tournament / get_tournament).
// Skip otomatis setelah 000005 drop fungsi tournament.
func TestIntegrationTournamentParity(t *testing.T) {
	url := os.Getenv("MAJADU_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("MAJADU_TEST_DATABASE_URL not set — skipping integration test")
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
	ctx := context.Background()

	var reg *string
	if err := pool.QueryRow(ctx,
		`SELECT to_regprocedure('get_tournament(text)')::text`).Scan(&reg); err != nil {
		t.Fatalf("check function: %v", err)
	}
	if reg == nil {
		t.Skip("get_tournament sudah di-drop — tournament read/write-path Go sudah satu-satunya")
	}

	ts := NewTournamentStore(pool, schema)
	id := "it-tourn-" + fmt.Sprintf("%d", time.Now().UnixNano())

	// create
	created, err := ts.Save(ctx, id, buildTestTournament("Parity Tournament"))
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if created.Version == nil || *created.Version != 1 {
		t.Fatalf("expected version 1, got %v", created.Version)
	}
	defer cleanupTournament(ctx, pool, id)

	// parity: Go Load vs SQL get_tournament
	goSnap, err := ts.Load(ctx, id)
	if err != nil {
		t.Fatalf("go load: %v", err)
	}
	var sqlRaw []byte
	if err := pool.QueryRow(ctx, `SELECT get_tournament($1)`, id).Scan(&sqlRaw); err != nil {
		t.Fatalf("sql get_tournament: %v", err)
	}
	sqlSnap := &domain.TournamentSnapshot{}
	if err := json.Unmarshal(sqlRaw, sqlSnap); err != nil {
		t.Fatalf("decode sql tournament: %v", err)
	}
	if !reflect.DeepEqual(goSnap, sqlSnap) {
		gb, _ := json.Marshal(goSnap)
		sb, _ := json.Marshal(sqlSnap)
		t.Fatalf("TOURNAMENT PARITY MISMATCH\nGO : %s\nSQL: %s", gb, sb)
	}

	// update: skor group match + version check
	upd := buildTestTournament("Parity Tournament")
	upd.Version = ptrInt(1)
	// set skor beberapa group match
	for i := range upd.Matches {
		if upd.Matches[i].Phase == "group" {
			a, b := 21, 18
			upd.Matches[i].ScoreA = &a
			upd.Matches[i].ScoreB = &b
		}
	}
	updated, err := ts.Save(ctx, id, upd)
	if err != nil {
		t.Fatalf("update: %v", err)
	}
	if updated.Version == nil || *updated.Version != 2 {
		t.Fatalf("expected version 2, got %v", updated.Version)
	}
	goSnap2, _ := ts.Load(ctx, id)
	var sqlRaw2 []byte
	if err := pool.QueryRow(ctx, `SELECT get_tournament($1)`, id).Scan(&sqlRaw2); err != nil {
		t.Fatalf("sql get_tournament 2: %v", err)
	}
	sqlSnap2 := &domain.TournamentSnapshot{}
	if err := json.Unmarshal(sqlRaw2, sqlSnap2); err != nil {
		t.Fatalf("decode sql tournament 2: %v", err)
	}
	if !reflect.DeepEqual(goSnap2, sqlSnap2) {
		t.Fatal("TOURNAMENT PARITY MISMATCH setelah update skor")
	}

	// version mismatch → tolak
	stale := buildTestTournament("Parity Tournament")
	stale.Version = ptrInt(99)
	if _, err := ts.Save(ctx, id, stale); !errorsIs(err) {
		t.Fatalf("expected version mismatch, got %v", err)
	}
}

func errorsIs(err error) bool {
	return err != nil
}

// TestIntegrationRegisterIdempotent — register dua kali → id sama; dan
// resolveTournamentPlayer auto-register nama baru.
func TestIntegrationRegisterIdempotent(t *testing.T) {
	url := os.Getenv("MAJADU_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("MAJADU_TEST_DATABASE_URL not set — skipping integration test")
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
	ctx := context.Background()

	ps := NewPlayerStore(pool)
	name := fmt.Sprintf("Reg Test %d", time.Now().UnixNano()%100000)
	id1, err := ps.Register(ctx, name, name, "M")
	if err != nil {
		t.Fatalf("register 1: %v", err)
	}
	id2, err := ps.Register(ctx, name, name, "M")
	if err != nil {
		t.Fatalf("register 2: %v", err)
	}
	if id1 != id2 {
		t.Fatalf("idempotent gagal: %s != %s", id1, id2)
	}

	// register via alias berbeda (case/whitespace) → id sama
	id3, err := ps.Register(ctx, "  "+name+"  ", name, "M")
	if err != nil {
		t.Fatalf("register 3: %v", err)
	}
	if id3 != id1 {
		t.Fatalf("alias harus resolve ke pemain sama: %s != %s", id3, id1)
	}
}

// TestIntegrationTournamentList — create tournament lalu list → muncul di daftar.
func TestIntegrationTournamentList(t *testing.T) {
	url := os.Getenv("MAJADU_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("MAJADU_TEST_DATABASE_URL not set — skipping integration test")
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
	ctx := context.Background()

	ts := NewTournamentStore(pool, schema)
	id := "it-tlist-" + fmt.Sprintf("%d", time.Now().UnixNano())
	if _, err := ts.Save(ctx, id, buildTestTournament("List Test Tournament")); err != nil {
		t.Fatalf("create: %v", err)
	}
	defer cleanupTournament(ctx, pool, id)

	metas, err := ts.List(ctx)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	found := false
	for _, m := range metas {
		if m.ID == id && m.Name == "List Test Tournament" {
			found = true
			if m.Date == "" {
				t.Fatal("date kosong di metadata")
			}
		}
	}
	if !found {
		t.Fatalf("tournament %s tidak muncul di list: %+v", id, metas)
	}
}

func cleanupTournament(ctx context.Context, pool *pgxpool.Pool, id string) {
	pool.Exec(ctx, `DELETE FROM tournaments WHERE share_code = $1`, id)
}
