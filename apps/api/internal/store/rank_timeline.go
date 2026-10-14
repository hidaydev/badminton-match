package store

import (
	"context"

	"majadu-api/internal/domain"
)

// ── Rank achievement (medal peringkat) ────────────────────────────────────
// Papan poin dihitung saat baca, jadi riwayat peringkat direkonstruksi dari
// rating_events: untuk setiap tanggal event, papan dihitung ulang (window,
// best_n, dan filter min-sesi yang SAMA dengan papan publik) lalu peringkat
// tiap pemain dicatat. Dipakai medal "Rank" (best rank) dan "Top-3 Streak".

// rankStat — ringkasan peringkat seorang pemain dari timeline.
type rankStat struct {
	best       int    // peringkat terbaik (minimum); 0 = tak pernah masuk papan
	bestDate   string // tanggal pertama kali peringkat terbaik diraih
	streak     int    // run terpanjang berturut-turut di top-3
	streakDate string // tanggal run terpanjang pertama kali tercapai
}

// rankTimeline — tanggal event (ascending) + papan per tanggal
// (player_id → rank). Memakai boardRowsFromEntries supaya definisi papan
// identik dengan papan publik (termasuk filter min-sesi).
func (s *SessionStore) rankTimeline(ctx context.Context, cfg domain.RatingConfig) ([]string, map[string]map[string]int, error) {
	rows, err := s.pool.Query(ctx, `
		SELECT DISTINCT date::text FROM `+s.schema+`.rating_events
		ORDER BY date`)
	if err != nil {
		return nil, nil, err
	}
	dates := []string{}
	for rows.Next() {
		var d string
		if err := rows.Scan(&d); err != nil {
			rows.Close()
			return nil, nil, err
		}
		dates = append(dates, d)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}

	names, err := s.playerNames(ctx)
	if err != nil {
		return nil, nil, err
	}

	byDate := make(map[string]map[string]int, len(dates))
	for _, d := range dates {
		entries, err := s.sessionEntries(ctx, cfg, d)
		if err != nil {
			return nil, nil, err
		}
		m := map[string]int{}
		for _, r := range boardRowsFromEntries(entries, cfg, names, 0) {
			m[r.PlayerID] = r.Rank
		}
		byDate[d] = m
	}
	return dates, byDate, nil
}

// computeRankStats — best rank + top-3 streak dari timeline. "Berturut-turut"
// = tanggal event yang berurutan (keputusan produk 2026-10-14: per tanggal
// event, bukan bucket kalender). Pemain yang absen dari papan pada satu
// tanggal memutus run.
func computeRankStats(dates []string, ranksByDate map[string]map[string]int) map[string]rankStat {
	all := map[string]bool{}
	for _, m := range ranksByDate {
		for pid := range m {
			all[pid] = true
		}
	}
	out := make(map[string]rankStat, len(all))
	cur := map[string]int{}
	for _, d := range dates {
		m := ranksByDate[d]
		for pid := range all {
			st := out[pid]
			r, present := m[pid]
			if present && (st.best == 0 || r < st.best) {
				st.best = r
				st.bestDate = d
			}
			if present && r <= 3 {
				cur[pid]++
			} else {
				cur[pid] = 0
			}
			if cur[pid] > st.streak {
				st.streak = cur[pid]
				st.streakDate = d
			}
			out[pid] = st
		}
	}
	return out
}

// backfillRankMedals — tulis medal rank + top-3 streak dari timeline.
func (s *SessionStore) backfillRankMedals(ctx context.Context, addMedal func(string, domain.MedalDef, int64, string, map[string]string)) error {
	cfg, err := s.LoadRatingConfig(ctx, false)
	if err != nil {
		return err
	}
	dates, ranksByDate, err := s.rankTimeline(ctx, cfg)
	if err != nil {
		return err
	}
	if len(dates) == 0 {
		return nil
	}
	stats := computeRankStats(dates, ranksByDate)
	rankDef := mustMedal("rank")
	streakDef := mustMedal("rank_streak")
	for pid, st := range stats {
		if st.best > 0 {
			addMedal(pid, rankDef, int64(st.best), st.bestDate, nil)
		}
		if st.streak > 0 {
			addMedal(pid, streakDef, int64(st.streak), st.streakDate, nil)
		}
	}
	return nil
}
