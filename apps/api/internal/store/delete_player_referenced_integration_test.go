package store

import (
	"context"
	"errors"
	"testing"

	"majadu-api/internal/domain"
)

// TestIntegrationDeletePlayerReferencedRequiresForce — regresi tombol Delete
// yang tampak rusak untuk 94% pemain di prod.
//
// Gejala yang dilaporkan: "remove player tidak bisa, lalu tambah pemain tidak
// bisa". Akar masalahnya: delete_player menolak menghapus pemain yang masih
// dipakai sesi (pengaman anti data-loss), dan UI tidak pernah mengirim force.
// Handler menganggap penolakan itu kegagalan database (500 generic), sehingga
// pesan yang bisa ditindaklanjuti tidak sampai ke pengguna.
//
// Yang dikunci di sini:
//  1. tanpa force → error ErrPlayerReferenced (bukan error mentah), dan data
//     TIDAK terhapus (rollback);
//  2. dengan force → pemain benar-benar hilang;
//  3. sesudah force, nama yang sama bisa didaftarkan ulang sebagai pemain BARU
//     (dulu dapat id lama karena pemain tak pernah terhapus).
func TestIntegrationDeletePlayerReferencedRequiresForce(t *testing.T) {
	st, schema := ratingTestEnv(t)
	ctx := context.Background()
	ps := NewPlayerStore(st.pool, schema)

	const prefix = "it-delref"
	cleanup := func() {
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.session_players WHERE session_id IN (SELECT id FROM `+schema+`.sessions WHERE share_code LIKE '`+prefix+`%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.scheduled_game_players WHERE scheduled_game_internal_id IN (SELECT internal_id FROM `+schema+`.scheduled_games WHERE session_id IN (SELECT id FROM `+schema+`.sessions WHERE share_code LIKE '`+prefix+`%'))`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.scheduled_games WHERE session_id IN (SELECT id FROM `+schema+`.sessions WHERE share_code LIKE '`+prefix+`%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.sessions WHERE share_code LIKE '`+prefix+`%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.rating_players WHERE player_id IN (SELECT id FROM `+schema+`.players WHERE canonical_name LIKE 'ITDELREF%')`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.player_aliases WHERE alias_name LIKE 'itdelref%'`)
		_, _ = st.pool.Exec(ctx, `DELETE FROM `+schema+`.players WHERE canonical_name LIKE 'ITDELREF%'`)
	}
	cleanup()
	t.Cleanup(cleanup)

	pid, err := ps.Register(ctx, "ITDELREF One", "", "M")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	// Sesi berisi pemain ini → memicu guard delete_player.
	var sid string
	if err := st.pool.QueryRow(ctx, `
		INSERT INTO `+schema+`.sessions (share_code, session_date, title, slot_minutes, status, source)
		VALUES ($1, DATE '2026-09-27', 'ITDELREF', 60, 'locked', 'manual')
		RETURNING id::text`, prefix+"-s").Scan(&sid); err != nil {
		t.Fatalf("insert session: %v", err)
	}
	if _, err := st.pool.Exec(ctx, `
		INSERT INTO `+schema+`.session_players (session_id, player_id, source_name, player_ref, gender, tier)
		VALUES ($1::uuid, $2::uuid, 'ITDELREF One', $3, 'M', 3)`, sid, pid, prefix+"-ref"); err != nil {
		t.Fatalf("insert session_players: %v", err)
	}

	// 1) Tanpa force → ditolak dengan sentinel, bukan error mentah.
	err = st.DeletePlayer(ctx, pid, false)
	if !errors.Is(err, ErrPlayerReferenced) {
		t.Fatalf("DeletePlayer tanpa force: err=%v, want ErrPlayerReferenced", err)
	}
	var stillThere int
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.players WHERE id=$1::uuid`, pid).Scan(&stillThere); err != nil {
		t.Fatalf("count: %v", err)
	}
	if stillThere != 1 {
		t.Fatal("pemain ikut terhapus padahal delete ditolak — rollback bocor")
	}

	// 2) Dengan force → pemain benar-benar hilang.
	if err := st.DeletePlayer(ctx, pid, true); err != nil {
		t.Fatalf("DeletePlayer force: %v", err)
	}
	if err := st.pool.QueryRow(ctx, `SELECT count(*) FROM `+schema+`.players WHERE id=$1::uuid`, pid).Scan(&stillThere); err != nil {
		t.Fatalf("count setelah force: %v", err)
	}
	if stillThere != 0 {
		t.Fatal("pemain masih ada setelah force delete")
	}

	// 3) Nama sama → pemain BARU (id berbeda). Inilah yang dulu terasa
	//    "tidak bisa menambah" karena id lama masih dikembalikan.
	newID, err := ps.Register(ctx, "ITDELREF One", "", "M")
	if err != nil {
		t.Fatalf("register ulang: %v", err)
	}
	if newID == pid {
		t.Fatalf("register ulang mengembalikan id lama %s — pemain tidak pernah terhapus", pid)
	}
}

var _ = domain.Player{}
