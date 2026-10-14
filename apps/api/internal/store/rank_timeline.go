package store

import (
	"context"
	"strings"

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

// rankMedalSets — himpunan pemain yang MASIH berhak atas medal rank / streak
// dari satu kali perhitungan timeline. `ok=false` artinya timeline tidak bisa
// dihitung (tanpa event) → rekonsiliasi dilewati, jangan hapus apa pun.
type rankMedalSets struct {
	ok      bool
	ranks   []string
	streaks []string
}

// backfillRankMedals — stage medal rank + top-3 streak dari timeline dan
// kembalikan himpunan pemain yang berhak, untuk rekonsiliasi baris lama
// (lihat purgeStaleRankMedals). Tidak menulis apa pun ke DB; baris yang
// di-stage ditulis oleh pemanggil.
func (s *SessionStore) backfillRankMedals(ctx context.Context, addMedal func(string, domain.MedalDef, int64, string, map[string]string)) (rankMedalSets, error) {
	cfg, err := s.LoadRatingConfig(ctx, false)
	if err != nil {
		return rankMedalSets{}, err
	}
	dates, ranksByDate, err := s.rankTimeline(ctx, cfg)
	if err != nil {
		return rankMedalSets{}, err
	}
	if len(dates) == 0 {
		return rankMedalSets{}, nil
	}
	stats := computeRankStats(dates, ranksByDate)
	rankDef := mustMedal("rank")
	streakDef := mustMedal("rank_streak")
	sets := rankMedalSets{ok: true}
	for pid, st := range stats {
		if st.best > 0 {
			sets.ranks = append(sets.ranks, pid)
			addMedal(pid, rankDef, int64(st.best), st.bestDate, nil)
		}
		if st.streak > 0 {
			sets.streaks = append(sets.streaks, pid)
			addMedal(pid, streakDef, int64(st.streak), st.streakDate, nil)
		}
	}
	return sets, nil
}

// purgeStaleRankMedals — buang medal rank / top-3 streak milik pemain yang
// sudah TIDAK lagi berhak. Medal rank sepenuhnya turunan dari papan, jadi saat
// definisi papan berubah (mis. ambang entri minimum naik) pemain bisa keluar
// dari papan sementara medalnya tetap nyangkut: klausa upsert hanya memperbaiki
// nilai, tidak pernah menghapus baris.
//
// Dipanggil SETELAH baris pengganti ditulis supaya tidak ada jendela di mana
// medal yang sah sudah terhapus tapi penggantinya belum ada.
func (s *SessionStore) purgeStaleRankMedals(ctx context.Context, sets rankMedalSets) error {
	if !sets.ok {
		return nil
	}
	// player_id digabung jadi string lalu dipecah di SQL: hindari encoding
	// array uuid lewat driver, dan id bersih dari koma.
	for _, t := range []struct {
		key  string
		pids []string
	}{
		{domain.MedalKey("rank"), sets.ranks},
		{domain.MedalKey("rank_streak"), sets.streaks},
	} {
		if _, err := s.pool.Exec(ctx, `
			DELETE FROM `+s.schema+`.player_achievements pa
			WHERE pa.achievement_key = $1
			  AND NOT (pa.player_id = ANY(string_to_array($2, ',')::uuid[]))`,
			t.key, strings.Join(t.pids, ",")); err != nil {
			return err
		}
	}
	return nil
}
