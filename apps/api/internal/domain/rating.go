package domain

// ── Tipe pendukung rating (pasca-pensiun Glicko, 2026-09-29) ───────────────
// Mesin Glicko (RATING_ENGINE_DESIGN.md §3) sudah dihapus — perhitungan
// rating tidak lagi dijalankan. Yang tersisa di sini hanya TIPE yang masih
// dipakai jalur ingest/rebuild untuk bookkeeping dan penulisan
// rating_deltas (fakta pertandingan, bahan baku papan poin BWF).

// RatingState — rating + deviation seorang pemain.
type RatingState struct {
	Rating float64
	RD     float64
}

// RatingOpponent — lawan (rating + rd) yang ikut dihitung expected.
type RatingOpponent struct {
	Rating float64
	RD     float64
}

// RatingOutcome — hasil per pemain: 1 menang, 0 kalah, 0.5 seri (tidak
// terjadi di badminton — disediakan untuk kompatibilitas).
const (
	OutcomeWin  = 1.0
	OutcomeLoss = 0.0
	OutcomeDraw = 0.5
)

// ─────────────────────────────────────────────────────────────────────────────
// Mesin Glicko DIHAPUS 2026-09-29 (pensiun Glicko).
//
// Fungsi-fungsi berikut dulu di sini dan sudah dipindahkan ke git history:
//   ratingQ, G, ExpectedScore, MarginOfVictory, GrowRD, round2, round4,
//   Round2, Round4, TierForRating, Provisional, DecayFactor, ActiveFloor,
//   TeamSizeWeight, VolatilityFactor, GlickoUpdate.
//
// Perhitungan rating sudah tidak dijalankan: poin BWF memakai sticky tier
// (lihat RANKING_POIN_BWF_RANCANGAN.md §4.5), dan rating_deltas hanya
// menyimpan fakta pertandingan (team/outcome). Tipe RatingState/RatingOpponent
// dipertahankan karena bookkeeping ingest/rebuild masih memakainya.
// ─────────────────────────────────────────────────────────────────────────────
