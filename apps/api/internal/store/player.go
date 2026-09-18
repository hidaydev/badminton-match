package store

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// PlayerStore — registry pemain + statistik (read-path di Go).
type PlayerStore struct {
	pool   *pgxpool.Pool
	schema string
}

// NewPlayerStore — buat PlayerStore dengan pool koneksi + schema.
// Schema wajib eksplisit: fallback diam-diam ke "bm" pernah membuat env dev
// menulis ke schema prod (tabel di-qualify schema, search_path tidak menolong).
func NewPlayerStore(pool *pgxpool.Pool, schema string) *PlayerStore {
	return &PlayerStore{pool: pool, schema: schema}
}

// PlayerSummary — baris dari list_players (read-path port bm.list_players).
type PlayerSummary struct {
	PlayerID  string `json:"playerId"`
	Name      string `json:"name"`
	Gender    string `json:"gender"`
	Tier      int    `json:"tier"`      // tier penampilan terakhir (legacy)
	TierInduk string `json:"tierInduk"` // tier induk STICKY (players.tier) — admin
}

// List — daftar pemain terdaftar (port bm.list_players): gender dan tier
// diambil dari players table (canonical), urut by lower(name).
func (s *PlayerStore) List(ctx context.Context) ([]PlayerSummary, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT p.id::text, p.canonical_name, COALESCE(p.gender, ''), COALESCE(p.tier, '')
		FROM players p
		ORDER BY lower(p.canonical_name)`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]PlayerSummary, 0)
	for rows.Next() {
		var p PlayerSummary
		if err := rows.Scan(&p.PlayerID, &p.Name, &p.Gender, &p.TierInduk); err != nil {
			return nil, err
		}
		// Read-time filter placeholder (ABSENT_TBD_PLAYERS_DESIGN.md §5.5) —
		// pemain legacy "free*" disembunyikan dari daftar tanpa dihapus.
		if domain.IsPlaceholderName(p.Name) {
			continue
		}
		// Map canonical tier text (D..A+) → numeric (1..8)
		p.Tier = tierTextToNum(p.TierInduk)
		out = append(out, p)
	}
	return out, rows.Err()
}

// tierTextToNum — konversi tier text (D..A+) ke numeric (1..8).
func tierTextToNum(t string) int {
	switch strings.ToUpper(t) {
	case "D":
		return 1
	case "D+":
		return 2
	case "C":
		return 3
	case "C+":
		return 4
	case "B":
		return 5
	case "B+":
		return 6
	case "A":
		return 7
	case "A+":
		return 8
	default:
		return 2 // default D+
	}
}

// Register — registry pemain (port bm.register_player): idempotent dan
// TOCTOU-safe (re-query alias setelah INSERT ON CONFLICT DO NOTHING).
func (s *PlayerStore) Register(ctx context.Context, name, canonicalName, gender string) (string, error) {
	if canonicalName == "" {
		canonicalName = name
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(ctx)) }()

	pid, err := registerPlayerInTx(ctx, tx, s.schema, name, canonicalName, gender)
	if err != nil {
		return "", err
	}
	if err := tx.Commit(ctx); err != nil {
		return "", err
	}
	return pid, nil
}

// SetTierOnRegister — set tier induk saat registrasi pemain baru (POST /players
// dengan tier opsional). First-set saja (tier IS NULL). Validasi 8-tier.
// Dipindah ke PlayerStore supaya handler tidak perlu orkestrasi dua store.
func (s *PlayerStore) SetTierOnRegister(ctx context.Context, playerID, tier string) error {
	if !domain.ValidTier(tier) {
		return fmt.Errorf("%w: tier must be 8-tier (D..A+)", ErrValidation)
	}
	_, err := s.pool.Exec(ctx, `UPDATE `+s.schema+`.players SET tier = $2 WHERE id = $1::uuid AND tier IS NULL`,
		playerID, tier)
	return err
}

// Stats — statistik karier pemain (port bm.get_player_stats_compat) → JSON.
// Pemain tidak dikenal → statistik kosong dengan `name` = nama yang dicari.
func (s *PlayerStore) Stats(ctx context.Context, name string) ([]byte, error) {
	return computePlayerStats(ctx, s.pool, name)
}

// RenamePlayer — rename canonical player (admin, BACKLOG_ANALYSIS A5).
// Anti-collision: nama baru yang sudah resolve ke player LAIN ditolak.
// Alias nama lama disimpan → referensi historis (snapshot sesi, stats)
// tetap resolve. Rating leaderboard (player_id) tidak terpengaruh.
func (s *PlayerStore) RenamePlayer(ctx context.Context, playerID, newName string) error {
	newNorm := domain.NormalizePlayerName(newName)
	if newNorm == "" {
		return fmt.Errorf("%w: player name must not be blank", ErrValidation)
	}
	if domain.IsPlaceholderName(newName) {
		return fmt.Errorf("%w: cannot rename to a placeholder name", ErrValidation)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var oldCanonical string
	if err := tx.QueryRow(ctx,
		`SELECT canonical_name FROM players WHERE id = $1::uuid`, playerID).Scan(&oldCanonical); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("%w: player not found", ErrNotFound)
		}
		return err
	}
	// Anti-collision: nama baru resolve ke pemain LAIN?
	var owner string
	err = tx.QueryRow(ctx, `
		SELECT p.id::text FROM player_aliases pa
		JOIN players p ON p.id = pa.player_id
		WHERE pa.alias_name = $1 LIMIT 1`, newNorm).Scan(&owner)
	if err == nil && owner != playerID {
		return fmt.Errorf("%w: name is already taken by another player", ErrValidation)
	}
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return err
	}

	if _, err := tx.Exec(ctx, `
		UPDATE players SET canonical_name = $2, updated_at = now() WHERE id = $1::uuid`,
		playerID, strings.TrimSpace(newName)); err != nil {
		return err
	}
	// Alias nama lama → referensi historis tetap resolve.
	oldNorm := domain.NormalizePlayerName(oldCanonical)
	if oldNorm != "" && oldNorm != newNorm {
		if _, err := tx.Exec(ctx, `
			INSERT INTO player_aliases (player_id, alias_name) VALUES ($1, $2)
			ON CONFLICT DO NOTHING`, playerID, oldNorm); err != nil {
			return err
		}
	}
	// Nama BARU juga harus jadi alias: resolve (session_write.resolvePlayerAliases,
	// tournament.resolveTournamentPlayer) HANYA lewat player_aliases, tidak ada
	// fallback ke players.canonical_name. Tanpa ini, rename membuat nama baru
	// tak resolvable → publish/rating sesi berikutnya gagal atau auto-register salah.
	if _, err := tx.Exec(ctx, `
		INSERT INTO player_aliases (player_id, alias_name) VALUES ($1, $2)
		ON CONFLICT (alias_name) DO NOTHING`, playerID, newNorm); err != nil {
		return err
	}

	// Nama tampilan di sesi lama ikut rename. session_players.source_name
	// dibekukan saat publish, jadi tanpa ini sesi lama tetap menampilkan nama
	// (beserta anotasi) yang sudah tak relevan — dan read-path Load() memakai
	// kolom ini. Filter player_id: placeholder (player_id NULL) tidak ikut.
	//
	// HANYA sesi yang belum pernah di-ingest: source_name ikut masuk
	// SourceFingerprint (berbasis nama). Mengubahnya pada sumber yang sudah
	// ter-ingest membuat fingerprint mismatch → manual re-ingest gagal
	// (ErrSourceChanged). Sesi ter-ingest sengaja dibiarkan memakai nama lama
	// agar re-ingest/reconcile tetap aman.
	if _, err := tx.Exec(ctx, `
		UPDATE `+s.schema+`.session_players sp
		SET source_name = $2
		WHERE sp.player_id = $1::uuid
		  AND NOT EXISTS (
			SELECT 1 FROM `+s.schema+`.rating_sources rs
			JOIN `+s.schema+`.sessions s ON s.share_code = rs.source_id
			WHERE s.id = sp.session_id AND rs.fingerprint <> ''
		  )`, playerID, strings.TrimSpace(newName)); err != nil {
		return err
	}

	// Nama beku di tournament — pair_name ("Dwi & Ismet") dan
	// tournament_team_players.player_name.
	//
	// Untuk team, player_name IKUT fingerprint (rating_extract extractTeamMatches
	// membaca kolom ini) → hanya tournament yang BELUM ter-ingest boleh diubah.
	// Untuk classic, fingerprint dibangun dari players.canonical_name (bukan
	// pair_name), jadi gate pair_name sebenarnya lebih konservatif dari yang
	// dibutuhkan — dipakai tetap agar konsisten & tidak mengejutkan.
	// Catatan: rename canonical_name tetap mengubah fingerprint classic yang
	// sudah ter-ingest (perilaku lama, di luar scope fix ini).
	// Selalu dijalankan (termasuk rename beda kapital saja) agar konsisten
	// dengan update session_players di atas; replacePlayerNameSegment
	// mengembalikan string apa adanya bila tidak ada segmen yang cocok.
	if err := s.propagateRenameToTournaments(ctx, tx, playerID, oldCanonical, strings.TrimSpace(newName)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// propagateRenameToTournaments — ganti nama pemain di pair_name + player_name
// tournament yang belum ter-ingest. pair_name adalah string gabungan, jadi
// penggantian hanya pada segmen utuh (lihat replacePlayerNameSegment).
// team_name adalah nama TIM, bukan nama pemain → tidak disentuh.
func (s *PlayerStore) propagateRenameToTournaments(ctx context.Context, tx pgx.Tx, playerID, oldName, newName string) error {
	// Pair yang memuat player ini, di tournament yang belum ter-ingest.
	rows, err := tx.Query(ctx, `
		SELECT DISTINCT tp.id::text, tp.pair_name
		FROM `+s.schema+`.tournament_pairs tp
		JOIN `+s.schema+`.tournament_pair_players tpp ON tpp.pair_id = tp.id
		JOIN `+s.schema+`.tournaments t ON t.id = tp.tournament_id
		WHERE tpp.player_id = $1::uuid
		  AND NOT EXISTS (
			SELECT 1 FROM `+s.schema+`.rating_sources rs
			WHERE rs.source_id = t.share_code AND rs.fingerprint <> ''
		  )`, playerID)
	if err != nil {
		return err
	}
	type pairUpdate struct {
		id      string
		newName string
	}
	updates := []pairUpdate{}
	for rows.Next() {
		var id, pairName string
		if err := rows.Scan(&id, &pairName); err != nil {
			rows.Close()
			return err
		}
		if repl := replacePlayerNameSegment(pairName, oldName, newName); repl != pairName {
			updates = append(updates, pairUpdate{id: id, newName: repl})
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, u := range updates {
		if _, err := tx.Exec(ctx, `
			UPDATE `+s.schema+`.tournament_pairs SET pair_name = $2 WHERE id = $1::uuid`, u.id, u.newName); err != nil {
			return err
		}
	}

	// team tournament: player_name denormalized (player_id tersimpan).
	if _, err := tx.Exec(ctx, `
		UPDATE `+s.schema+`.tournament_team_players ttp
		SET player_name = $2
		WHERE ttp.player_id = $1::uuid
		  AND NOT EXISTS (
			SELECT 1 FROM `+s.schema+`.tournament_teams tt
			JOIN `+s.schema+`.tournaments t ON t.id = tt.tournament_id
			JOIN `+s.schema+`.rating_sources rs
			  ON rs.source_id = t.share_code AND rs.fingerprint <> ''
			WHERE tt.id = ttp.team_id
		  )`, playerID, newName); err != nil {
		return err
	}
	return nil
}
