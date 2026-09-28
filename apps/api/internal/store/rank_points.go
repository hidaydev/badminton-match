package store

import (
	"context"
	"math"
	"sort"

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
		m = 1 // skor bisa melebihi target (mis. 30-28 di target 21); batasi
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

// popAverageRating — rata-rata rating populasi ber-riwayat (pembagi pengali).
// Pemain tanpa riwayat tidak ikut supaya mid kelas tidak menyeret rata-rata.
func (s *SessionStore) popAverageRating(ctx context.Context) (float64, error) {
	var avg *float64
	err := s.pool.QueryRow(ctx, `
		SELECT avg(rating) FROM `+s.schema+`.rating_players WHERE games_played > 0`).Scan(&avg)
	if err != nil {
		return 0, err
	}
	if avg == nil || *avg <= 0 {
		return 0, nil
	}
	return *avg, nil
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
// Rating lawan diambil dari rating_players SAAT INI (bukan saat match) —
// keputusan yang disadari: Glicko menjadi INPUT poin (§4.5).
func (s *SessionStore) sessionEntries(ctx context.Context, cfg domain.RatingConfig, asOf string) ([]rankPointEntryRow, error) {
	return s.sessionEntriesFor(ctx, cfg, asOf, "")
}

// sessionEntriesFor — sama seperti sessionEntries, tapi bila playerFilter tidak
// kosong hanya baris pemain itu yang diambil. Dipakai jalur satu-pemain supaya
// halaman detail tidak mengagregasi seluruh papan.
func (s *SessionStore) sessionEntriesFor(ctx context.Context, cfg domain.RatingConfig, asOf, playerFilter string) ([]rankPointEntryRow, error) {
	popAvg, err := s.popAverageRating(ctx)
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
		       rd.team,
		       COALESCE((
		           SELECT avg(rp2.rating)
		           FROM `+s.schema+`.rating_deltas rd2
		           JOIN `+s.schema+`.rating_players rp2 ON rp2.player_id = rd2.player_id
		           WHERE rd2.event_id = rd.event_id
		             AND rd2.team <> rd.team
		             AND rp2.games_played > 0
		       ), 0) AS opp_avg
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
	type acc struct {
		entry RankPointEntry
	}
	agg := map[string]*acc{}
	order := []string{}
	for rows.Next() {
		var playerID, sourceID, date, kind, team string
		var scoreA, scoreB, target int
		var oppAvg float64
		if err := rows.Scan(&playerID, &sourceID, &date, &kind, &scoreA, &scoreB, &target, &team, &oppAvg); err != nil {
			return nil, err
		}
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

		key := playerID + "\x00" + sourceID
		a, ok := agg[key]
		if !ok {
			a = &acc{entry: RankPointEntry{
				SourceID: sourceID, Date: date, Kind: kind,
			}}
			agg[key] = a
			order = append(order, key)
		}
		a.entry.Points += pts
		a.entry.Games++
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	out := make([]rankPointEntryRow, 0, len(order))
	for _, k := range order {
		a := agg[k]
		pid, _, _ := splitKey(k)
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

	// Kelompokkan per pemain, urut poin desc, ambil best_n.
	byPlayer := map[string][]RankPointEntry{}
	for _, e := range entries {
		byPlayer[e.playerID] = append(byPlayer[e.playerID], e.entry)
	}

	names, err := s.playerNames(ctx)
	if err != nil {
		return nil, err
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

	return &RankPointsBoard{
		WindowWeeks: cfg.RankWindowWeeks,
		BestN:       cfg.RankBestN,
		AsOf:        asOf,
		Rows:        rows,
	}, nil
}

// playerNames — peta player_id → canonical_name.
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
// Poin dihitung saat baca. Mengagregasi SELURUH papan lalu mencari satu baris
// berarti endpoint publik ini mengerjakan pekerjaan untuk ~119 pemain pada tiap
// request (3 query + agregasi semua event). Jalur ini menyaring satu pemain
// sejak di query, jadi biayanya tidak ikut jumlah pemain.
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

	entries, err := s.sessionEntriesFor(ctx, cfg, asOf, playerID)
	if err != nil {
		return nil, false, err
	}
	if len(entries) == 0 {
		return nil, false, nil
	}

	es := make([]RankPointEntry, 0, len(entries))
	for _, e := range entries {
		es = append(es, e.entry)
	}
	sortEntries(es)

	n := cfg.RankBestN
	if len(es) < n {
		n = len(es)
	}
	total := 0.0
	for i := 0; i < n; i++ {
		total += es[i].Points
	}

	var name string
	if err := s.pool.QueryRow(ctx,
		`SELECT canonical_name FROM `+s.schema+`.players WHERE id = $1::uuid`, playerID).Scan(&name); err != nil {
		name = "" // nama bukan alasan gagal; baris tetap berguna lewat poinnya
	}

	// Peringkat = banyaknya pemain dengan poin LEBIH TINGGI + 1. Ini sama
	// dengan peringkat seri dibagi (1,2,2,4) yang dipakai papan penuh: dua
	// pemain berpoin sama mendapat angka yang sama.
	rank := 1
	if err := s.pool.QueryRow(ctx, `
		WITH pop AS (
			SELECT avg(rating) AS pop_avg FROM `+s.schema+`.rating_players WHERE games_played > 0
		),
		g AS (
			SELECT rd.player_id, re.source_id,
			       CASE WHEN rd.team = 'B' THEN abs(re.score_a - re.score_b)
			            ELSE abs(re.score_b - re.score_a) END AS margin,
			       re.target,
			       COALESCE((
			           SELECT avg(rp2.rating)
			           FROM `+s.schema+`.rating_deltas rd2
			           JOIN `+s.schema+`.rating_players rp2 ON rp2.player_id = rd2.player_id
			           WHERE rd2.event_id = rd.event_id
			             AND rd2.team <> rd.team
			             AND rp2.games_played > 0
			       ), 0) AS opp_avg
			FROM `+s.schema+`.rating_deltas rd
			JOIN `+s.schema+`.rating_events re ON re.id = rd.event_id
			WHERE re.date >= ($1::date - ($2 * 7))
			  AND re.date <= $1::date
			  AND re.target > 0
		),
		val AS (
			SELECT g.player_id, g.source_id, g.target,
			       $3::numeric * (0.5 + 0.5 * LEAST(1.0, g.margin::numeric / g.target))
			       * CASE WHEN $4::boolean
			              THEN LEAST($5::numeric, GREATEST($6::numeric,
			                   CASE WHEN pop.pop_avg > 0 AND g.opp_avg > 0
			                        THEN g.opp_avg / pop.pop_avg ELSE 1 END))
			              ELSE 1 END AS pts
			FROM g, pop
		),
		ent AS (
			SELECT player_id, source_id, sum(pts) AS entry_pts
			FROM val GROUP BY player_id, source_id
		),
		best AS (
			SELECT player_id, sum(entry_pts) AS total FROM (
				SELECT *, row_number() OVER (PARTITION BY player_id ORDER BY entry_pts DESC) rn
				FROM ent
			) x WHERE rn <= $7 GROUP BY player_id
		)
		SELECT count(*) + 1 FROM best WHERE round(total) > round($8::numeric)`,
		asOf, cfg.RankWindowWeeks, cfg.RankSessionBase, cfg.RankOpponentWeight,
		cfg.RankOpponentClamp[1], cfg.RankOpponentClamp[0], cfg.RankBestN, total).Scan(&rank); err != nil {
		return nil, false, err
	}

	return &RankPointRow{
		Rank:             rank,
		PlayerID:         playerID,
		Name:             name,
		Points:           math.Round(total),
		CountedEntries:   n,
		EntriesAvailable: len(es),
		ThinEvidence:     len(es) < cfg.RankThinEvidenceN,
		Breakdown:        es[:n],
	}, true, nil
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
