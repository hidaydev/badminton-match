package store

// TestIntegrationMergePlayers — verifikasi fitur merge player (isu #2):
// source main di sesi A, target main di sesi B (kasus duplikat nama real),
// lalu merge source → target. Semua referensi (alias, session) harus pindah,
// source hilang.
//
// Jalan: MAJADU_TEST_DATABASE_URL=postgres://majadu_app:...@localhost:15432/bm_dev \
//        MAJADU_TEST_DB_SCHEMA=bm_dev go test ./internal/store/ -run TestIntegrationMergePlayers -v

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"testing"
	"time"

	"majadu-api/internal/db"
	"majadu-api/internal/domain"
)

func TestIntegrationMergePlayers(t *testing.T) {
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
	ps := NewPlayerStore(pool)
	ctx := context.Background()

	mk := func(name string) domain.Player {
		return domain.Player{ID: "itm-" + name, Name: name, Gender: "M", Tier: 2}
	}
	src := mk("ITM Merge Source")
	tgt := mk("ITM Merge Target")
	o1 := mk("ITM Other One")
	o2 := mk("ITM Other Two")
	o3 := mk("ITM Other Three")
	for _, p := range []domain.Player{src, tgt, o1, o2, o3} {
		if _, err := ps.Register(ctx, p.Name, p.Name, p.Gender); err != nil {
			t.Fatalf("register %s: %v", p.Name, err)
		}
	}
	pid := func(name string) string {
		var id string
		if err := pool.QueryRow(ctx, `SELECT id::text FROM `+schema+`.players WHERE canonical_name=$1`, name).Scan(&id); err != nil {
			t.Fatalf("resolve %s: %v", name, err)
		}
		return id
	}
	srcID := pid(src.Name)
	tgtID := pid(tgt.Name)

	// ── Sesi A: source main. Sesi B: target main. (terpisah — kasus duplikat)
	sessionFor := func(label string, who domain.Player) (string, error) {
		id := "it-merge-" + label + "-" + fmt.Sprintf("%d", time.Now().UnixNano())
		snap := &domain.CloudSnapshot{
			Session: domain.SessionConfig{
				Title: "ITM " + label, Date: "2026-08-20", Courts: 1,
				SessionStart: "09:00", SlotMinutes: 20,
				CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
				PlayerCount: 4,
				CourtNames:  []string{"C1"},
			},
			Players:     []domain.Player{who, o1, o2, o3},
			FixMatches:  []domain.FixMatch{},
			Schedule:    []domain.ScheduleSlot{{Slot: 0, Court: 0, TeamA: [2]string{who.ID, o1.ID}, TeamB: [2]string{o2.ID, o3.ID}}},
			PlayedGames: []string{"0-0"},
			GameScores:  map[string]domain.GameScore{"0-0": {A: 21, B: 15}},
		}
		if _, err := st.Save(ctx, id, snap); err != nil {
			return "", err
		}
		return id, nil
	}
	sessA, err := sessionFor("src", src)
	if err != nil {
		t.Fatalf("create session A: %v", err)
	}
	sessB, err := sessionFor("tgt", tgt)
	if err != nil {
		t.Fatalf("create session B: %v", err)
	}

	count := func(q string, args ...any) int {
		var n int
		if err := pool.QueryRow(ctx, q, args...).Scan(&n); err != nil {
			t.Fatalf("count: %v", err)
		}
		return n
	}
	preAliasSrc := count(`SELECT count(*) FROM `+schema+`.player_aliases WHERE player_id=$1::uuid`, srcID)
	preSessSrc := count(`SELECT count(*) FROM `+schema+`.session_players WHERE player_id=$1::uuid`, srcID)
	preSessTgt := count(`SELECT count(*) FROM `+schema+`.session_players WHERE player_id=$1::uuid`, tgtID)
	t.Logf("before: src aliases=%d sessions=%d | tgt sessions=%d", preAliasSrc, preSessSrc, preSessTgt)
	if preSessSrc != 1 || preSessTgt != 1 {
		t.Fatalf("precondition gagal: src=%d tgt=%d", preSessSrc, preSessTgt)
	}

	// ── merge: source → target ──────────────────────────────────────────
	res, err := st.MergePlayers(ctx, tgtID, srcID)
	if err != nil {
		t.Fatalf("merge: %v", err)
	}
	t.Logf("merge result: %+v", res)

	// ── verifikasi ──────────────────────────────────────────────────────
	postSessSrc := count(`SELECT count(*) FROM `+schema+`.session_players WHERE player_id=$1::uuid`, srcID)
	postSessTgt := count(`SELECT count(*) FROM `+schema+`.session_players WHERE player_id=$1::uuid`, tgtID)
	if postSessSrc != 0 {
		t.Fatalf("source masih punya session_players: %d", postSessSrc)
	}
	if postSessTgt != preSessTgt+preSessSrc {
		t.Fatalf("target sessions=%d, harus %d", postSessTgt, preSessTgt+preSessSrc)
	}
	if res.SessionsMoved != preSessSrc {
		t.Fatalf("res.SessionsMoved=%d, harus %d", res.SessionsMoved, preSessSrc)
	}
	exists := count(`SELECT count(*) FROM `+schema+`.players WHERE id=$1::uuid`, srcID)
	if exists != 0 {
		t.Fatalf("source player masih ada: %d", exists)
	}
	aliasToTgt := count(`SELECT count(*) FROM `+schema+`.player_aliases WHERE player_id=$1::uuid`, tgtID)
	t.Logf("after: tgt aliases=%d sessions=%d | source hilang", aliasToTgt, postSessTgt)

	// ── cleanup ─────────────────────────────────────────────────────────
	if err := st.Delete(ctx, sessA); err != nil {
		t.Logf("cleanup A: %v", err)
	}
	if err := st.Delete(ctx, sessB); err != nil {
		t.Logf("cleanup B: %v", err)
	}
}
