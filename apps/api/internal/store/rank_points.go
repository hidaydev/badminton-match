package store

import (
	"context"
	"encoding/json"
	"math"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"

	"majadu-api/internal/domain"
)

// ── Ranking poin (papan publik ala BWF) ───────────────────────────────────
// RANKING_POIN_BWF_RANCANGAN.md §4.4–4.7.
//
// Papan publik memakai POIN, bukan Glicko: window bergulir 12 minggu, ambil
// 10 entri (sesi) terbaik. Glicko tetap mesin internal (generator/pairing +
// halaman detail pemain).
//
// Poin dihitung SAAT BACA (tidak ada tabel materialized) — dengan ~655 event
// agregasi ini remeh, dan tidak ada state yang bisa basi.

// RankPointEntry — satu entri (sesi) yang dihitung untuk seorang pemain.
type RankPointEntry struct {
	SourceID string  `json:"source_id"`
	Date     string  `json:"date"`
	Kind     string  `json:"kind"`
	Points   float64 `json:"points"`
	Games    int     `json:"games"`
	// Result — kunci hasil turnamen ("final", "runner_up", "sf", ...).
	// Kosong untuk entri sesi; dipakai breakdown di halaman pemain.
	Result string `json:"result,omitempty"`
}

// RankPointRow — satu baris papan ranking poin.
type RankPointRow struct {
	Rank             int              `json:"rank"`
	PlayerID         string           `json:"player_id"`
	Name             string           `json:"name"`
	Points           float64          `json:"points"`
	CountedEntries   int              `json:"counted_entries"`   // entri yang dihitung (≤ best_n)
	EntriesAvailable int              `json:"entries_available"` // entri tersedia di window
	ThinEvidence     bool             `json:"thin_evidence"`     // entri < ambang
	Breakdown        []RankPointEntry `json:"breakdown"`

	// Movement rank vs snapshot tanggal acuan sebelumnya (tabel
	// rank_snapshots). RankDelta > 0 = naik (rank mengecil); 0 = tetap;
	// null = belum ada pembanding (pemain baru di papan).
	PrevRank  *int `json:"prev_rank"`
	RankDelta *int `json:"rank_delta"`
}

// RankPointsBoard — hasil papan.
type RankPointsBoard struct {
	WindowWeeks int            `json:"window_weeks"`
	BestN       int            `json:"best_n"`
	AsOf        string         `json:"as_of"` // tanggal acuan window
	Rows        []RankPointRow `json:"rows"`
}

// gameValue — nilai satu game sesi: 250 × (0.5 + 0.5 × margin/target).
// Murni hasil; tidak ada poin kehadiran (§4.5).
func gameValue(base, margin, target float64) float64 {
	if target <= 0 {
		return 0
	}
	m := margin / target
	if m > 1 {
		m = 1 // clamp defensif: aturan main kini tak melebihi target (30/42), batasi jaga-jaga
	}
	return base * (0.5 + 0.5*m)
}

// opponentMultiplier — pengali kekuatan lawan (§4.5).
// rata-rata rating lawan / rata-rata rating populasi, dijepit [clampMin, clampMax].
// Tanpa ini papan berubah jadi daftar orang paling rajin (§2.1).
func opponentMultiplier(oppAvg, popAvg float64, clamp [2]float64) float64 {
	if popAvg <= 0 || oppAvg <= 0 {
		return 1
	}
	w := oppAvg / popAvg
	if w < clamp[0] {
		return clamp[0]
	}
	if w > clamp[1] {
		return clamp[1]
	}
	return w
}

// tierStrength — nilai kekuatan dari tier sticky, memakai band tengah
// ClassBands (D 1000-1199 → 1100, dst). Dipakai sebagai pengganti rating
// Glicko di pengali kekuatan lawan: tier stabil (tidak bergerak sendiri),
// jadi pengali tidak lagi bergantung mesin rating.
//
// ok=false bila tier kosong/tak dikenal → pemanggil memakai nilai netral.
func tierStrength(cfg domain.RatingConfig, tier string) (float64, bool) {
	band, ok := cfg.ClassBands[tier]
	if !ok {
		return 0, false
	}
	lo, hi := band[0], band[1]
	switch {
	case lo != nil && hi != nil:
		return (*lo + *hi) / 2, true
	case lo != nil: // band terbuka ke atas (A+): tebarkan 100 di atas batas
		return *lo + 100, true
	case hi != nil:
		return *hi - 100, true
	default:
		return 0, false
	}
}

// avgTierStrength — rata-rata nilai tier dari daftar tier dipisah koma
// (dari string_agg di SQL). "" / tier tak dikenal dilewati.
func avgTierStrength(cfg domain.RatingConfig, tiers string) float64 {
	if tiers == "" {
		return 0
	}
	var sum float64
	var n int
	for _, t := range strings.Split(tiers, ",") {
		if v, ok := tierStrength(cfg, t); ok {
			sum += v
			n++
		}
	}
	if n == 0 {
		return 0
	}
	return sum / float64(n)
}

// popTierStrength — rata-rata tierStrength populasi (pembagi pengali).
// Menggantikan rata-rata rating: keduanya sama-sama titik netral skala,
// sehingga rasio pengali tetap berpusat ~1.0 (diverifikasi pada data prod:
// rata-rata 1.004). Pemain tanpa tier tidak ikut.
func (s *SessionStore) popTierStrength(ctx context.Context, cfg domain.RatingConfig) (float64, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT tier FROM `+s.schema+`.players WHERE tier IS NOT NULL`)
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	var sum float64
	var n int
	for rows.Next() {
		var tier string
		if err := rows.Scan(&tier); err != nil {
			return 0, err
		}
		if v, ok := tierStrength(cfg, tier); ok {
			sum += v
			n++
		}
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	if n == 0 {
		return 0, nil
	}
	return sum / float64(n), nil
}

// rankLevel — satu baris rank_point_levels (§4.4 dokumen rancangan):
// kind → poin juara + rasio per ronde. Format baru = tambah baris, bukan
// ubah kode.
type rankLevel struct {
	champion float64
	ratios   map[string]float64
	enabled  bool
}

// defaultTournamentRatios — default §4.4; baris di rank_point_levels boleh
// menimpanya. Fallback mengisi kunci yang belum ada di data (mis. runner_up
// yang belum terisi di prod) supaya poin final tetap masuk akal.
var defaultTournamentRatios = map[string]float64{
	"final":       1.0,
	"runner_up":   0.85,
	"sf":          0.7,
	"qf":          0.55,
	"group":       0.4,
	"participant": 0.2,
}

// rankLevels — baca seluruh rank_point_levels (panggil sekali per query).
func (s *SessionStore) rankLevels(ctx context.Context) (map[string]rankLevel, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT kind, champion_points, round_ratios, enabled
		FROM `+s.schema+`.rank_point_levels`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := map[string]rankLevel{}
	for rows.Next() {
		var kind string
		var lv rankLevel
		var raw []byte
		if err := rows.Scan(&kind, &lv.champion, &raw, &lv.enabled); err != nil {
			return nil, err
		}
		if len(raw) > 0 {
			if err := json.Unmarshal(raw, &lv.ratios); err != nil {
				// Jangan jatuhkan SELURUH papan karena satu baris rusak:
				// kosongkan ratios → ratioOf jatuh ke default §4.4.
				if s.logger != nil {
					s.logger.Warn("rank_point_levels: round_ratios bukan objek numerik — memakai default",
						"kind", kind, "error", err)
				}
				lv.ratios = nil
			}
		}
		out[kind] = lv
	}
	return out, rows.Err()
}

// ratioOf — rasio hasil: data dulu, lalu default §4.4, terakhir 0.
func (lv rankLevel) ratioOf(key string) float64 {
	if v, ok := lv.ratios[key]; ok {
		return v
	}
	if v, ok := defaultTournamentRatios[key]; ok {
		return v
	}
	return 0
}

// tournPhaseRank — peringkat fase turnamen (makin tinggi makin jauh). "3rd"
// disetarakan "sf": perebutan juara-3 hanya diikuti yang kalah semifinal.
func tournPhaseRank(phase string) int {
	switch phase {
	case "final":
		return 4
	case "sf", "3rd":
		return 3
	case "qf":
		return 2
	case "group":
		return 1
	}
	return 0 // fase tak dikenal → tidak di atas grup
}

// tournResultKey — kunci rasio round_ratios untuk hasil SEORANG pemain di
// satu turnamen (§4.4): menang final → final; kalah final padahal menang di
// babak sebelumnya → runner_up; tidak menang match sama sekali →
// participant; selain itu → fase tertinggi yang dicapai.
func tournResultKey(bestRank int, finalOutcome string, anyWin bool) string {
	if !anyWin {
		return "participant"
	}
	if bestRank >= 4 {
		if finalOutcome == "W" {
			return "final"
		}
		return "runner_up"
	}
	switch bestRank {
	case 3:
		return "sf"
	case 2:
		return "qf"
	case 1:
		return "group"
	}
	return "participant" // fase tak dikenal → ikut saja
}

// rankPointEntryRow — hasil agregasi mentah per (pemain, sesi).
type rankPointEntryRow struct {
	playerID string
	entry    RankPointEntry
}

// sessionEntries — hitung entri poin per pemain per sesi dalam window.
//
// Satu sesi = satu entri (§ keputusan #1). Nilai entri = jumlah nilai game
// pemain itu di sesi tersebut, masing-masing dikali pengali kekuatan lawan.
//
// Kekuatan lawan diambil dari TIER STICKY lawan (band tengah ClassBands),
// bukan rating Glicko: pengali jadi tidak bergantung mesin rating, dan tier
// tidak bergerak sendiri sehingga poin sesi lama tidak berubah makna saat
// rating lawan naik/turun. Keputusan #§4.5 (revisi 2026-09-29).
func (s *SessionStore) sessionEntries(ctx context.Context, cfg domain.RatingConfig, asOf string) ([]rankPointEntryRow, error) {
	return s.sessionEntriesFor(ctx, cfg, asOf, "")
}

// sessionEntriesFor — sama seperti sessionEntries, tapi bila playerFilter tidak
// kosong hanya baris pemain itu yang diambil. Dipakai jalur satu-pemain supaya
// halaman detail tidak mengagregasi seluruh papan.
func (s *SessionStore) sessionEntriesFor(ctx context.Context, cfg domain.RatingConfig, asOf, playerFilter string) ([]rankPointEntryRow, error) {
	popAvg, err := s.popTierStrength(ctx, cfg)
	if err != nil {
		return nil, err
	}

	// $3 kosong → semua pemain. NULLIF agar perbandingan tidak memfilter apa pun.
	rows, err := s.pool.Query(ctx, `
		SELECT rd.player_id::text,
		       re.source_id,
		       re.date::text,
		       re.kind,
		       re.score_a, re.score_b, re.target,
		       rd.team, re.phase, rd.outcome,
		       COALESCE((
		           SELECT string_agg(COALESCE(p2.tier, ''), ',')
		           FROM `+s.schema+`.rating_deltas rd2
		           JOIN `+s.schema+`.players p2 ON p2.id = rd2.player_id
		           WHERE rd2.event_id = rd.event_id
		             AND rd2.team <> rd.team
		       ), '') AS opp_tiers
		FROM `+s.schema+`.rating_deltas rd
		JOIN `+s.schema+`.rating_events re ON re.id = rd.event_id
		WHERE re.date >= ($1::date - ($2 * 7))
		  AND re.date <= $1::date
		  AND re.target > 0
		  AND rd.player_id = COALESCE(NULLIF($3, '')::uuid, rd.player_id)`,
		asOf, cfg.RankWindowWeeks, playerFilter)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	// Agregasi di Go: satu entri per (pemain, source_id).
	levels, err := s.rankLevels(ctx)
	if err != nil {
		return nil, err
	}
	type acc struct {
		entry RankPointEntry
		// Turnamen dengan baris level aktif: fase tertinggi + pernah menang.
		// Points dihitung ulang setelah loop (champion × rasio), bukan Σ
		// gameValue — poin turnamen tidak pernah terbagi per game (§4.4).
		useLevel  bool
		bestRank  int
		anyWin    bool
		finalOutc string
	}
	agg := map[string]*acc{}
	order := []string{}
	for rows.Next() {
		var playerID, sourceID, date, kind, team, phase, outcome string
		var scoreA, scoreB, target int
		var oppTiers string
		if err := rows.Scan(&playerID, &sourceID, &date, &kind, &scoreA, &scoreB,
			&target, &team, &phase, &outcome, &oppTiers); err != nil {
			return nil, err
		}
		// Kekuatan lawan = rata-rata band tengah tier lawan. Lawan tanpa tier
		// (atau tier tak dikenal) dilewati; bila tidak ada satu pun yang
		// terbaca, oppAvg=0 → opponentMultiplier mengembalikan 1 (netral).
		oppAvg := avgTierStrength(cfg, oppTiers)

		key := playerID + "\x00" + sourceID
		a, ok := agg[key]
		if !ok {
			a = &acc{entry: RankPointEntry{
				SourceID: sourceID, Date: date, Kind: kind,
			}}
			agg[key] = a
			order = append(order, key)
		}
		a.entry.Games++

		// Turnamen dengan level aktif → akumulasi hasil, tanpa gameValue.
		if lv, isT := levels[kind]; kind != "session" && isT && lv.enabled {
			a.useLevel = true
			if r := tournPhaseRank(phase); r > a.bestRank {
				a.bestRank = r
			}
			if outcome == "W" {
				a.anyWin = true
			}
			if phase == "final" {
				a.finalOutc = outcome
			}
			continue
		}

		// Sesi (atau turnamen tanpa baris level) → rumus game §4.5.
		margin := float64(scoreB - scoreA)
		if team == "B" {
			margin = float64(scoreA - scoreB)
		}
		if margin < 0 {
			margin = -margin
		}
		pts := gameValue(cfg.RankSessionBase, margin, float64(target))
		if cfg.RankOpponentWeight {
			pts *= opponentMultiplier(oppAvg, popAvg, cfg.RankOpponentClamp)
		}
		a.entry.Points += pts
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	out := make([]rankPointEntryRow, 0, len(order))
	for _, k := range order {
		a := agg[k]
		pid, _, _ := splitKey(k)
		if a.useLevel {
			lv := levels[a.entry.Kind]
			res := tournResultKey(a.bestRank, a.finalOutc, a.anyWin)
			a.entry.Points = lv.champion * lv.ratioOf(res)
			a.entry.Result = res
		}
		out = append(out, rankPointEntryRow{playerID: pid, entry: a.entry})
	}
	return out, nil
}

// splitKey — pecah key agregasi "playerID\x00sourceID".
func splitKey(k string) (string, string, bool) {
	for i := 0; i < len(k); i++ {
		if k[i] == 0 {
			return k[:i], k[i+1:], true
		}
	}
	return k, "", false
}

// RankPointsBoard — papan ranking poin publik.
//
// asOf kosong → pakai tanggal event terakhir (bukan CURRENT_DATE) supaya
// window stabil walau tidak ada aktivitas baru; ini juga membuat hasil
// deterministik untuk test.
func (s *SessionStore) RankPointsBoard(ctx context.Context, asOf string, limit int) (*RankPointsBoard, error) {
	cfg, err := s.LoadRatingConfig(ctx, false)
	if err != nil {
		return nil, err
	}
	if cfg.RankWindowWeeks <= 0 {
		cfg.RankWindowWeeks = 12
	}
	if cfg.RankBestN <= 0 {
		cfg.RankBestN = 10
	}

	if asOf == "" {
		d, err := s.latestEventDate(ctx)
		if err != nil {
			return nil, err
		}
		if d == "" {
			return &RankPointsBoard{WindowWeeks: cfg.RankWindowWeeks, BestN: cfg.RankBestN, Rows: []RankPointRow{}}, nil
		}
		asOf = d
	}

	entries, err := s.sessionEntries(ctx, cfg, asOf)
	if err != nil {
		return nil, err
	}
	names, err := s.playerNames(ctx)
	if err != nil {
		return nil, err
	}
	rows := boardRowsFromEntries(entries, cfg, names, limit)
	// Movement dibaca dari snapshot SEBELUM asOf. Kalau tabel belum punya
	// baris sebelumnya, movement tetap null (bukan error) — papan tetap tampil.
	if err := s.applyRankMovement(ctx, asOf, rows); err != nil {
		if s.logger != nil {
			s.logger.Warn("rank movement dilewati", "as_of", asOf, "error", err)
		}
	}

	return &RankPointsBoard{
		WindowWeeks: cfg.RankWindowWeeks,
		BestN:       cfg.RankBestN,
		AsOf:        asOf,
		Rows:        rows,
	}, nil
}

// playerNames — peta player_id → canonical_name.
// boardRowsFromEntries — kelompokkan entri per pemain, totalkan best_n,
// urut, beri peringkat (seri dibagi: 1,2,2,4). SATU logika untuk papan
// penuh dan jalur per-pemain: duplikasi logika membuat rank per-pemain
// menyimpang dari papan begitu poin turnamen masuk (audit ke-7 — CTE SQL
// lama di RankPointsForPlayer tidak tahu rank_point_levels).
// limit 0 = tanpa pemotongan.
func boardRowsFromEntries(entries []rankPointEntryRow, cfg domain.RatingConfig,
	names map[string]string, limit int) []RankPointRow {
	byPlayer := map[string][]RankPointEntry{}
	for _, e := range entries {
		byPlayer[e.playerID] = append(byPlayer[e.playerID], e.entry)
	}

	rows := []RankPointRow{}
	for pid, es := range byPlayer {
		sortEntries(es)
		avail := len(es)
		n := cfg.RankBestN
		if avail < n {
			n = avail
		}
		total := 0.0
		for i := 0; i < n; i++ {
			total += es[i].Points
		}
		rows = append(rows, RankPointRow{
			PlayerID:         pid,
			Name:             names[pid],
			Points:           math.Round(total),
			CountedEntries:   n,
			EntriesAvailable: avail,
			ThinEvidence:     avail < cfg.RankThinEvidenceN,
			Breakdown:        es[:n],
		})
	}

	// Urut: poin desc, bukti lebih banyak dulu, lalu nama, lalu ID (deterministik).
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].Points != rows[j].Points {
			return rows[i].Points > rows[j].Points
		}
		if rows[i].EntriesAvailable != rows[j].EntriesAvailable {
			return rows[i].EntriesAvailable > rows[j].EntriesAvailable
		}
		if rows[i].Name != rows[j].Name {
			return rows[i].Name < rows[j].Name
		}
		return rows[i].PlayerID < rows[j].PlayerID
	})
	if limit > 0 && len(rows) > limit {
		rows = rows[:limit]
	}
	// Peringkat seri dibagi (1,2,2,4) — pola sama dengan leaderboard Glicko.
	for i := range rows {
		if i > 0 && rows[i].Points == rows[i-1].Points {
			rows[i].Rank = rows[i-1].Rank
		} else {
			rows[i].Rank = i + 1
		}
	}
	return rows
}

// CaptureRankSnapshot — simpan posisi papan saat ini sebagai snapshot
// pada tanggal asOf. Idempoten per (as_of, player_id): pemanggilan berulang
// di hari yang sama menimpa baris lama, jadi snapshot selalu mencerminkan
// papan terakhir yang dihitung.
//
// Dipanggil ticker auto-ingest (30 menit). asOf kosong → tanggal event
// terakhir. Tidak ada event → tidak ada yang disimpan (papan kosong).
func (s *SessionStore) CaptureRankSnapshot(ctx context.Context) (int, error) {
	cfg, err := s.LoadRatingConfig(ctx, false)
	if err != nil {
		return 0, err
	}
	if cfg.RankWindowWeeks <= 0 {
		cfg.RankWindowWeeks = 12
	}
	if cfg.RankBestN <= 0 {
		cfg.RankBestN = 10
	}

	asOf, err := s.latestEventDate(ctx)
	if err != nil {
		return 0, err
	}
	if asOf == "" {
		return 0, nil
	}

	entries, err := s.sessionEntries(ctx, cfg, asOf)
	if err != nil {
		return 0, err
	}
	if len(entries) == 0 {
		return 0, nil
	}
	rows := boardRowsFromEntries(entries, cfg, nil, 0)

	batch := &pgx.Batch{}
	for _, r := range rows {
		batch.Queue(`
			INSERT INTO `+s.schema+`.rank_snapshots (as_of, player_id, rank, points)
			VALUES ($1::date, $2::uuid, $3, $4)
			ON CONFLICT (as_of, player_id) DO UPDATE
			SET rank = EXCLUDED.rank,
			    points = EXCLUDED.points,
			    captured_at = now()`,
			asOf, r.PlayerID, r.Rank, r.Points)
	}
	br := s.pool.SendBatch(ctx, batch)
	defer br.Close()
	for range rows {
		if _, err := br.Exec(); err != nil {
			return 0, err
		}
	}
	return len(rows), nil
}

// rankSnapshotRanks — rank dari snapshot tanggal acuan SEBELUM asOf.
//
// "Sebelumnya" = as_of terbesar yang < asOf, bukan asOf-1 hari: papan
// berubah saat ada sesi baru, dan tanggal acuan melompat mengikuti event
// terakhir. Snapshot yang lebih tua dipakai sebagai pembanding supaya
// movement tetap bermakna walau ada hari tanpa aktivitas.
func (s *SessionStore) rankSnapshotRanks(ctx context.Context, asOf string) (map[string]int, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT player_id::text, rank
		FROM `+s.schema+`.rank_snapshots
		WHERE as_of = (
			SELECT max(as_of) FROM `+s.schema+`.rank_snapshots WHERE as_of < $1::date
		)`, asOf)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := map[string]int{}
	for rows.Next() {
		var pid string
		var rank int
		if err := rows.Scan(&pid, &rank); err != nil {
			return nil, err
		}
		out[pid] = rank
	}
	return out, rows.Err()
}

// applyRankMovement — isi PrevRank/RankDelta dari snapshot sebelumnya.
// Tabel mungkin belum ada isinya (awal musim) → biarkan null.
func (s *SessionStore) applyRankMovement(ctx context.Context, asOf string, rows []RankPointRow) error {
	prev, err := s.rankSnapshotRanks(ctx, asOf)
	if err != nil {
		return err
	}
	if len(prev) == 0 {
		return nil
	}
	for i := range rows {
		if pr, ok := prev[rows[i].PlayerID]; ok {
			p := pr
			d := pr - rows[i].Rank // rank mengecil = naik → delta positif
			rows[i].PrevRank = &p
			rows[i].RankDelta = &d
		}
	}
	return nil
}

func (s *SessionStore) playerNames(ctx context.Context) (map[string]string, error) {
	rows, err := s.pool.Query(ctx,
		`SELECT id::text, canonical_name FROM `+s.schema+`.players`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var id, name string
		if err := rows.Scan(&id, &name); err != nil {
			return nil, err
		}
		out[id] = name
	}
	return out, rows.Err()
}

// RankPointsForPlayer — papan satu pemain, dipakai halaman detail publik.
//
// Poin dihitung saat baca. Mengagregasi SELURUH papan lalu mencari satu baris:
// dengan ~119 pemain dan ~2.5k event biayanya remeh, dan konsistensi dengan
// papan lebih penting daripada menghemat agregasi (audit ke-7).
//
// found=false bila pemain tidak punya entri di window sama sekali.
func (s *SessionStore) RankPointsForPlayer(ctx context.Context, playerID string) (*RankPointRow, bool, error) {
	cfg, err := s.LoadRatingConfig(ctx, false)
	if err != nil {
		return nil, false, err
	}
	if cfg.RankWindowWeeks <= 0 {
		cfg.RankWindowWeeks = 12
	}
	if cfg.RankBestN <= 0 {
		cfg.RankBestN = 10
	}

	asOf, err := s.latestEventDate(ctx)
	if err != nil {
		return nil, false, err
	}
	if asOf == "" {
		return nil, false, nil
	}

	// Papan penuh, lalu ambil baris pemain ini: rank, total, breakdown —
	// SEMUA dihitung logika yang sama dengan papan. CTE SQL terpisah yang
	// dulu dipakai untuk menghindari agregasi penuh ternyata tidak tahu
	// rank_point_levels → rank halaman pemain menyimpang dari papan begitu
	// poin turnamen ada (audit ke-7). Agregasi on-read remeh untuk skala
	// data ini (§4.6).
	entries, err := s.sessionEntries(ctx, cfg, asOf)
	if err != nil {
		return nil, false, err
	}
	names, err := s.playerNames(ctx)
	if err != nil {
		return nil, false, err
	}
	all := boardRowsFromEntries(entries, cfg, names, 0)
	if err := s.applyRankMovement(ctx, asOf, all); err != nil {
		if s.logger != nil {
			s.logger.Warn("rank movement dilewati", "as_of", asOf, "error", err)
		}
	}
	for i := range all {
		if all[i].PlayerID == playerID {
			return &all[i], true, nil
		}
	}
	return nil, false, nil
}

// latestEventDate — tanggal acuan window: event terakhir (bukan CURRENT_DATE)
// supaya hasil stabil saat tidak ada aktivitas baru. "" bila belum ada event.
func (s *SessionStore) latestEventDate(ctx context.Context) (string, error) {
	var d *string
	if err := s.pool.QueryRow(ctx,
		`SELECT max(date)::text FROM `+s.schema+`.rating_events`).Scan(&d); err != nil {
		return "", err
	}
	if d == nil {
		return "", nil
	}
	return *d, nil
}

// sortEntries — poin desc, lalu tanggal terbaru (deterministik).
func sortEntries(es []RankPointEntry) {
	sort.Slice(es, func(i, j int) bool {
		if es[i].Points != es[j].Points {
			return es[i].Points > es[j].Points
		}
		return es[i].Date > es[j].Date
	})
}
