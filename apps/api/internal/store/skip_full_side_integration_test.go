package store

import (
	"context"
	"fmt"
	"testing"
	"time"

	"majadu-api/internal/domain"
)

// TestIntegrationSkipFullSideStillRated — regression kasus nyata (sesi
// 873febe423e045a7, game 1-1): satu tim habis di-skip per game karena kedua
// pemainnya digantikan orang lain. Skor tetap sah, jadi game HARUS tetap dinilai
// untuk tim lawan. Sebelumnya gate `len(eligibleA)==0 || len(eligibleB)==0`
// membuang game ini, sehingga pemain yang benar-benar main kehilangan satu game
// (baik di leaderboard sesi maupun di rating).
//
// Yang diverifikasi:
//
//   - rating event tetap dibuat untuk game tsb
//
//   - hanya tim yang main yang dapat delta
//
//   - pemain yang di-skip TIDAK dapat delta
//
//     Jalan: MAJADU_TEST_DATABASE_URL=... MAJADU_TEST_DB_SCHEMA=bm \
//     go test ./internal/store/ -run TestIntegrationSkipFullSideStillRated -v
func TestIntegrationSkipFullSideStillRated(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()

	players := []domain.Player{
		{ID: "itsk1", Name: "ITSK Ega", Gender: "M", Tier: 5},
		{ID: "itsk2", Name: "ITSK Ismet", Gender: "M", Tier: 5},
		{ID: "itsk3", Name: "ITSK Vira", Gender: "F", Tier: 3},
		{ID: "itsk4", Name: "ITSK Fathur", Gender: "M", Tier: 3},
	}
	if err := st.EnsurePlayersRegistered(ctx, players); err != nil {
		t.Fatalf("register: %v", err)
	}

	id := fmt.Sprintf("it-rating-skip-%d", time.Now().UnixNano())
	// Scoped cleanup — DB bisa dipakai bersama data lain.
	t.Cleanup(func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_events WHERE source_id LIKE 'it-rating-skip-%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_sources WHERE source_id LIKE 'it-rating-skip-%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (
			SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'ITSK %')`)
		_, _ = st.pool.Exec(ctx, `UPDATE `+schema+`.sessions SET status='draft' WHERE share_code LIKE 'it-rating-skip-%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE 'it-rating-skip-%'`)
	})

	// Satu game: Ega+Ismet vs Vira+Fathur, skor 30-27. Vira & Fathur di-skip.
	snap := &domain.CloudSnapshot{
		Session: domain.SessionConfig{
			Title: "Rating IT skip", Date: testSessionDate(2), Courts: 1,
			SessionStart: "09:00", SlotMinutes: 20,
			CourtTimes:  []domain.CourtTime{{Start: "09:00", End: "10:00"}},
			PlayerCount: len(players),
			CourtNames:  []string{"C1"},
		},
		Players:    players,
		FixMatches: []domain.FixMatch{},
		Schedule: []domain.ScheduleSlot{
			{Slot: 0, Court: 0, TeamA: [2]string{"itsk1", "itsk2"}, TeamB: [2]string{"itsk3", "itsk4"}},
		},
		PlayedGames:    []string{"0-0"},
		GameScores:     map[string]domain.GameScore{"0-0": {A: 30, B: 27}},
		SkippedPlayers: map[string][]string{"0-0": {"itsk3", "itsk4"}},
	}
	created, err := st.Save(ctx, id, snap)
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	// Skor tetap tersimpan walau satu tim habis di-skip — inilah yang membuat
	// game-nya tetap sah untuk tim lawan.
	if sc, ok := created.GameScores["0-0"]; !ok || sc.A != 30 || sc.B != 27 {
		t.Fatalf("skor 0-0 harus tetap tersimpan, got %+v", created.GameScores)
	}
	if got := created.SkippedPlayers["0-0"]; len(got) != 2 {
		t.Fatalf("skippedPlayers 0-0 harus 2, got %v", got)
	}
	saveLock(t, st, ctx, id)

	res, err := st.IngestSession(ctx, id)
	if err != nil {
		t.Fatalf("ingest: %v", err)
	}
	// Sebelum fix: Processed = 0 (game dibuang karena satu sisi kosong).
	if res.Processed != 1 {
		t.Fatalf("processed = %d, want 1 (game dengan satu tim habis di-skip tetap dinilai)", res.Processed)
	}

	pid := map[string]string{}
	for _, p := range players {
		var got string
		if err := st.pool.QueryRow(ctx,
			`SELECT id::text FROM `+schema+`.players WHERE canonical_name = $1`, p.Name).Scan(&got); err != nil {
			t.Fatalf("find %s: %v", p.Name, err)
		}
		pid[p.Name] = got
	}
	deltasFor := func(name string) int {
		var n int
		if err := st.pool.QueryRow(ctx, `
			SELECT count(*) FROM `+schema+`.rating_deltas rd
			JOIN `+schema+`.rating_events re ON re.id = rd.event_id
			WHERE re.source_id LIKE 'it-rating-skip-%' AND rd.player_id = $1::uuid`, pid[name]).Scan(&n); err != nil {
			t.Fatalf("count delta %s: %v", name, err)
		}
		return n
	}

	if got := deltasFor("ITSK Ega"); got != 1 {
		t.Fatalf("Ega main di game tsb → harus dapat delta, got %d", got)
	}
	if got := deltasFor("ITSK Ismet"); got != 1 {
		t.Fatalf("Ismet main di game tsb → harus dapat delta, got %d", got)
	}
	if got := deltasFor("ITSK Vira"); got != 0 {
		t.Fatalf("Vira di-skip → tidak boleh dapat delta, got %d", got)
	}
	if got := deltasFor("ITSK Fathur"); got != 0 {
		t.Fatalf("Fathur di-skip → tidak boleh dapat delta, got %d", got)
	}
}
