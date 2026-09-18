package store

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"testing"
	"time"

	"majadu-api/internal/db"
	"majadu-api/internal/domain"
)

// TestIntegrationStatsAbsentSkipPlayer — verifikasi semantik absent_policy
// = "skip_player" (kontrak produk saat ini, lihat commit b4ad7af dan
// absent_policy_verify_test.go): game yang memuat pemain is_absent TETAP
// dihitung untuk pemain lain; hanya pemain absent sendiri yang dikecualikan.
// Semantik lama "void seluruh game" sudah tidak dipakai.
// Hanya jalan dengan MAJADU_TEST_DATABASE_URL.
func TestIntegrationStatsAbsentSkipPlayer(t *testing.T) {
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
	st := NewSessionStore(pool, schema)
	ps := NewPlayerStore(pool, schema)
	ctx := context.Background()

	// Pre-count placeholder (data legacy bm_dev sudah punya "free*" dari
	// Juni–Juli; yang diuji adalah run ini TIDAK menambah baris baru).
	var prePlaceholder, preAlias int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.players WHERE canonical_name = 'free 1'`).Scan(&prePlaceholder); err != nil {
		t.Fatalf("pre-count placeholder: %v", err)
	}
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.player_aliases WHERE alias_name = 'free 1'`).Scan(&preAlias); err != nil {
		t.Fatalf("pre-count alias: %v", err)
	}

	players := []domain.Player{
		{ID: "itv1", Name: "ITV One", Gender: "M", Tier: 1},
		{ID: "itv2", Name: "ITV Two", Gender: "M", Tier: 2},
		{ID: "itv3", Name: "ITV Three", Gender: "M", Tier: 3},
		{ID: "itv4", Name: "ITV Four", Gender: "M", Tier: 4},
		{ID: "itvX", Name: "ITV Absent", Gender: "M", Tier: 1},
		{ID: "itvF", Name: "free 1", Gender: "M", Tier: 2}, // placeholder — TIDAK boleh diregistrasi
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}

	id := "it-void-" + fmt.Sprintf("%d", time.Now().UnixNano())
	// 4 game:
	//   g1 (0-0): itv1+itv2 vs itv3+itv4 — VALID, skor 21-18
	//   g2 (1-0): itvX+itv2 vs itv3+itv4 — VOID (itvX absent)
	//   g3 (2-0): itv1+itv2 vs itv3+itvX — VOID (itvX absent)
	//   g4 (3-0): itv1+itv2 vs itv3+itvF — VOID (itvF placeholder "free 1")
	snap := &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "ITV", Date: testSessionDate(2), Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: len(players),
			CourtNames:  []string{"C1"},
		},
		Players:    players,
		FixMatches: []domain.FixMatch{},
		Schedule: []domain.ScheduleSlot{
			{Slot: 0, Court: 0, TeamA: [2]string{"itv1", "itv2"}, TeamB: [2]string{"itv3", "itv4"}},
			{Slot: 1, Court: 0, TeamA: [2]string{"itvX", "itv2"}, TeamB: [2]string{"itv3", "itv4"}},
			{Slot: 2, Court: 0, TeamA: [2]string{"itv1", "itv2"}, TeamB: [2]string{"itv3", "itvX"}},
			{Slot: 3, Court: 0, TeamA: [2]string{"itv1", "itv2"}, TeamB: [2]string{"itv3", "itvF"}},
		},
		PlayedGames: []string{"0-0", "1-0", "2-0", "3-0"},
		GameScores: map[string]domain.GameScore{
			"0-0": {A: 21, B: 18},
			"1-0": {A: 21, B: 10},
			"2-0": {A: 12, B: 21},
			"3-0": {A: 21, B: 19},
		},
		AbsentPlayers: []string{"itvX"},
	}

	created, err := st.Save(ctx, id, snap)
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	defer func() {
		cleanupSession(ctx, st, id)
	}()

	// Pastikan snapshot round-trip memuat absent
	if len(created.AbsentPlayers) != 1 || created.AbsentPlayers[0] != "itvX" {
		t.Fatalf("absent not persisted: %+v", created.AbsentPlayers)
	}

	type statsShape struct {
		GamesPlayed   int `json:"gamesPlayed"`
		Wins          int `json:"wins"`
		Losses        int `json:"losses"`
		PointsFor     int `json:"pointsFor"`
		PointsAgainst int `json:"pointsAgainst"`
	}
	get := func(name string) statsShape {
		raw, err := ps.Stats(ctx, name)
		if err != nil {
			t.Fatalf("stats %s: %v", name, err)
		}
		var s statsShape
		if err := json.Unmarshal(raw, &s); err != nil {
			t.Fatalf("unmarshal %s: %v", name, err)
		}
		return s
	}

	// Kontrak skip_player: game yang memuat pemain lain yang absent tetap
	// dihitung. g1 0-0 (21-18), g2 1-0 (21-10), g3 2-0 (12-21), g4 3-0 (21-19);
	// itvX absent; itvF placeholder.
	// itv1 main g1(A menang), g3(A kalah), g4(A menang).
	s1 := get("ITV One")
	if s1.GamesPlayed != 3 || s1.Wins != 2 || s1.Losses != 1 || s1.PointsFor != 54 || s1.PointsAgainst != 58 {
		t.Fatalf("ITV One stats salah: %+v", s1)
	}

	// itv2 main g1(A menang), g2(A menang), g3(A kalah), g4(A menang).
	s2 := get("ITV Two")
	if s2.GamesPlayed != 4 || s2.Wins != 3 || s2.Losses != 1 || s2.PointsFor != 75 || s2.PointsAgainst != 68 {
		t.Fatalf("ITV Two stats salah: %+v", s2)
	}

	// itv3 main g1(B kalah), g2(B kalah), g3(B menang), g4(B kalah).
	s3 := get("ITV Three")
	if s3.GamesPlayed != 4 || s3.Wins != 1 || s3.Losses != 3 || s3.PointsFor != 68 || s3.PointsAgainst != 75 {
		t.Fatalf("ITV Three stats salah: %+v", s3)
	}

	// itv4 main g1(B kalah), g2(B kalah).
	s4 := get("ITV Four")
	if s4.GamesPlayed != 2 || s4.Wins != 0 || s4.Losses != 2 || s4.PointsFor != 28 || s4.PointsAgainst != 42 {
		t.Fatalf("ITV Four stats salah: %+v", s4)
	}

	// itvX (absent): satu-satunya yang dikecualikan → 0 game.
	sx := get("ITV Absent")
	if sx.GamesPlayed != 0 || sx.Wins != 0 || sx.Losses != 0 {
		t.Fatalf("absent player stats salah (harusnya 0 game): %+v", sx)
	}

	// Placeholder "free 1" TIDAK boleh ter-registrasi BARU oleh run ini.
	var postPlaceholder, postAlias int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.players WHERE canonical_name = 'free 1'`).Scan(&postPlaceholder); err != nil {
		t.Fatalf("post-count placeholder: %v", err)
	}
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.player_aliases WHERE alias_name = 'free 1'`).Scan(&postAlias); err != nil {
		t.Fatalf("post-count alias: %v", err)
	}
	if postPlaceholder != prePlaceholder {
		t.Fatalf("placeholder 'free 1' ter-registrasi BARU ke players: pre=%d post=%d", prePlaceholder, postPlaceholder)
	}
	if postAlias != preAlias {
		t.Fatalf("placeholder 'free 1' ter-registrasi BARU ke aliases: pre=%d post=%d", preAlias, postAlias)
	}

	// Round-trip: pemain placeholder tetap ada di snapshot (source_name tersimpan)
	loaded, err := st.Load(ctx, id)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	found := false
	for _, p := range loaded.Players {
		if p.Name == "free 1" {
			found = true
		}
	}
	if !found {
		t.Fatal("placeholder 'free 1' hilang dari snapshot setelah load")
	}
}
