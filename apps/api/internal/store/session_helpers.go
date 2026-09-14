// Helper murni write-path: parsing, klasifikasi, skip logic.

package store

import (
	"errors"
	"strings"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5/pgconn"
)

// playerRef — padanan trim(player.value->>'id') di SQL.
func playerRef(id string) string { return strings.TrimSpace(id) }

// nilableInt — int ≥ 0 dikirim apa adanya, -1 → NULL (absent_order/played_order).
func nilableInt(n int) *int {
	if n < 0 {
		return nil
	}
	return &n
}

// playedOrder — played_order = legacy_order + 1 saat game played (mirror SQL).
func playedOrder(legacyOrder int, isPlayed bool) int {
	if !isPlayed {
		return -1 // NULL
	}
	return legacyOrder + 1
}

// splitGameKey — pecah "slot-court". STRICT: kedua bagian harus digit murni
// (tanpa spasi, tanpa tanda negatif) — Sscanf terlalu lenient (menerima
// " 0-0" dan "0--1" → court negatif). Dipakai granular path, jadi malformed
// key harus ditolak, bukan di-normalisasi.
func splitGameKey(key string) (int, int, bool) {
	parts := strings.SplitN(key, "-", 2)
	if len(parts) != 2 {
		return 0, 0, false
	}
	slot, ok1 := parseUintStrict(parts[0])
	court, ok2 := parseUintStrict(parts[1])
	if !ok1 || !ok2 {
		return 0, 0, false
	}
	return slot, court, true
}

// parseUintStrict — parse non-negative integer dari string digit murni.
func parseUintStrict(s string) (int, bool) {
	if s == "" {
		return 0, false
	}
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
		if n > 1<<30 { // guard overflow
			return 0, false
		}
	}
	return n, true
}

// isLockNotAvailable — deteksi SQLSTATE 55P03 (lock_not_available).
func isLockNotAvailable(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "55P03"
}

// countDecidedGames — hitung jumlah game yang sudah "beres" di snapshot:
// sudah punya skor ATAU sengaja tidak dimainkan (seluruh pemainnya di-skip —
// skippedPlayers per-game memuat semua pemain game tsb). Game yang dibiarkan
// kosong (belum skor, belum di-skip) tetap dihitung belum beres.
func countDecidedGames(snap *domain.CloudSnapshot) int {
	count := 0
	for _, g := range snap.Schedule {
		key := domain.GameKey(g.Slot, g.Court)
		if _, ok := snap.GameScores[key]; ok {
			count++
			continue
		}
		if gameFullySkipped(g, snap.SkippedPlayers[key]) {
			count++
		}
	}
	return count
}

// gameFullySkipped — true jika seluruh pemain game di-skip (sengaja tidak
// dimainkan). Butuh minimal satu pemain non-blank — game tanpa pemain tidak
// dianggap beres.
func gameFullySkipped(g domain.ScheduleSlot, skipped []string) bool {
	skipSet := make(map[string]struct{}, len(skipped))
	for _, id := range skipped {
		skipSet[id] = struct{}{}
	}
	players := 0
	for _, id := range g.TeamA {
		if id == "" {
			continue
		}
		players++
		if _, ok := skipSet[id]; !ok {
			return false
		}
	}
	for _, id := range g.TeamB {
		if id == "" {
			continue
		}
		players++
		if _, ok := skipSet[id]; !ok {
			return false
		}
	}
	return players > 0
}
