package handler

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"majadu-api/internal/httperr"
	"majadu-api/internal/store"
)

// ── Rating handler (RATING_ENGINE_DESIGN.md §6) ───────────────────────────
// Write endpoints admin-only (MAJADU_ADMIN_TOKEN). Read endpoints publik.

// RatingsHandler — HTTP handlers untuk rating engine.
type RatingsHandler struct {
	Store  *store.SessionStore
	Logger *slog.Logger
	// AdminToken — token admin (Authorization: Bearer). Kosong = semua
	// endpoint admin ditolak 401.
	AdminToken string
}

// RequireAdmin — middleware admin (Authorization: Bearer MAJADU_ADMIN_TOKEN).
func (h *RatingsHandler) RequireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return adminGuard(h.AdminToken, h.Logger, next)
}

// body struct — request ingest/revert/finalize.
type ratingBody struct {
	SessionID    string `json:"sessionId"`
	TournamentID string `json:"tournamentId"`
	SourceID     string `json:"sourceId"`
	Finalized    *bool  `json:"finalized"`
	StartDate    string `json:"startDate"`
	Kind         string `json:"kind"` // session | tournament (replay-source)
}

// mapRatingError — sentinel store → httperr (design §6 error contract).
func mapRatingError(err error) *httperr.Error {
	switch {
	case errors.Is(err, store.ErrSourceNotFound):
		return httperr.NotFound("rating source not found")
	case errors.Is(err, store.ErrSourceChanged):
		return httperr.SourceChanged("rating source changed since ingest — revert required")
	case errors.Is(err, store.ErrOutOfOrder):
		return httperr.Conflict("operation out of order")
	case errors.Is(err, store.ErrSourceNotFinal):
		return httperr.Conflict("rating source not final")
	default:
		return httperr.Wrap(httperr.CodeDatabase, "rating operation failed", err)
	}
}

// IngestSession — POST /ratings/ingest-session {sessionId} → 200 IngestResult.
func (h *RatingsHandler) IngestSession(w http.ResponseWriter, r *http.Request) {
	var body ratingBody
	if err := decodeJSON(r, &body); err != nil || body.SessionID == "" {
		httperr.WriteError(w, h.Logger, httperr.Validation("sessionId is required"))
		return
	}
	res, err := h.Store.IngestSession(r.Context(), body.SessionID)
	if err != nil {
		httperr.WriteError(w, h.Logger, mapRatingError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, res)
}

// IngestTournament — POST /ratings/ingest-tournament {tournamentId} → 200.
func (h *RatingsHandler) IngestTournament(w http.ResponseWriter, r *http.Request) {
	var body ratingBody
	if err := decodeJSON(r, &body); err != nil || body.TournamentID == "" {
		httperr.WriteError(w, h.Logger, httperr.Validation("tournamentId is required"))
		return
	}
	res, err := h.Store.IngestTournament(r.Context(), body.TournamentID)
	if err != nil {
		httperr.WriteError(w, h.Logger, mapRatingError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, res)
}

// RevertSession — POST /ratings/revert-session {sessionId} → full rebuild.
func (h *RatingsHandler) RevertSession(w http.ResponseWriter, r *http.Request) {
	var body ratingBody
	if err := decodeJSON(r, &body); err != nil || body.SessionID == "" {
		httperr.WriteError(w, h.Logger, httperr.Validation("sessionId is required"))
		return
	}
	res, err := h.Store.RevertSource(r.Context(), body.SessionID, "session")
	if err != nil {
		httperr.WriteError(w, h.Logger, mapRatingError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, res)
}

// RevertTournament — POST /ratings/revert-tournament {tournamentId}.
func (h *RatingsHandler) RevertTournament(w http.ResponseWriter, r *http.Request) {
	var body ratingBody
	if err := decodeJSON(r, &body); err != nil || body.TournamentID == "" {
		httperr.WriteError(w, h.Logger, httperr.Validation("tournamentId is required"))
		return
	}
	res, err := h.Store.RevertSource(r.Context(), body.TournamentID, "tournament")
	if err != nil {
		httperr.WriteError(w, h.Logger, mapRatingError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, res)
}

// FinalizeSource — POST /ratings/sources/{sourceId}/finalize {finalized}.
func (h *RatingsHandler) FinalizeSource(w http.ResponseWriter, r *http.Request) {
	sourceID := r.PathValue("sourceId")
	var body ratingBody
	if err := decodeJSON(r, &body); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("finalized is required"))
		return
	}
	if body.Finalized == nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("finalized is required"))
		return
	}
	err := h.Store.SetSourceFinalized(r.Context(), sourceID, *body.Finalized)
	if err != nil {
		httperr.WriteError(w, h.Logger, mapRatingError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// RebuildAll — POST /ratings/rebuild-all (admin) — full rebuild dari events
// tersisa (tool tuning config).
func (h *RatingsHandler) RebuildAll(w http.ResponseWriter, r *http.Request) {
	n, err := h.Store.RebuildAll(r.Context())
	if err != nil {
		httperr.WriteError(w, h.Logger, mapRatingError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]int{"rebuilt": n})
}

// ReplayAll — POST /ratings/replay-all (admin) — proses ulang SEMUA sumber
// rating sejak season_start + rebuild sekali.
//
// Jalur pemulihan untuk sumber yang sudah ter-ingest lalu berubah (skor
// diedit setelah sesi ter-lock). Ticker hanya menyapu sumber yang belum
// pernah di-ingest, sehingga kasus itu tidak pernah diperbaiki otomatis.
func (h *RatingsHandler) ReplayAll(w http.ResponseWriter, r *http.Request) {
	report, err := h.Store.ReplayAll(r.Context())
	if err != nil {
		httperr.WriteError(w, h.Logger, mapRatingError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, report)
}

// ReplaySource — POST /ratings/replay-source {sourceId, kind} (admin) —
// proses ulang satu sesi/turnamen + rebuild.
func (h *RatingsHandler) ReplaySource(w http.ResponseWriter, r *http.Request) {
	var body ratingBody
	if err := decodeJSON(r, &body); err != nil || body.SourceID == "" {
		httperr.WriteError(w, h.Logger, httperr.Validation("sourceId is required"))
		return
	}
	kind := body.Kind
	if kind == "" {
		kind = "session"
	}
	if kind != "session" && kind != "tournament" {
		httperr.WriteError(w, h.Logger, httperr.Validation("kind must be 'session' or 'tournament'"))
		return
	}
	report, err := h.Store.ReplaySource(r.Context(), body.SourceID, kind)
	if err != nil {
		httperr.WriteError(w, h.Logger, mapRatingError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, report)
}

// Rankings — GET /rankings?limit&as_of → PUBLIK.
//
// Papan poin ala BWF: total poin dari N entri (sesi) terbaik dalam window
// bergulir (default 12 minggu, 10 terbaik). Poin dihitung saat baca.
func (h *RatingsHandler) Rankings(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit := atoiSafe(q.Get("limit"), 200)
	asOf := q.Get("as_of")
	// as_of masuk langsung sebagai $1::date di store — string rusak di sana
	// melempar error Postgres yang berujung 500. Tangkap di sini sebagai 400.
	if asOf != "" {
		if _, err := time.Parse("2006-01-02", asOf); err != nil {
			httperr.WriteError(w, h.Logger, httperr.Validation("as_of harus format YYYY-MM-DD"))
			return
		}
	}
	board, err := h.Store.RankPointsBoard(r.Context(), asOf, limit)
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to fetch rankings", err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, board)
}

// PlayerRankPoints — GET /rankings/players/{playerId} → PUBLIK.
//
// Poin pemain di halaman detail. found=false (bukan 404) bila belum ada entri
// di window: pemain baru tetap boleh membuka halamannya.
func (h *RatingsHandler) PlayerRankPoints(w http.ResponseWriter, r *http.Request) {
	pid := r.PathValue("playerId")
	// id yang bukan format UUID tidak mungkin menunjuk pemain mana pun, dan
	// cast ::uuid di store akan melempar error Postgres (500). Kontrak
	// found=false dipertahankan untuk kedua kasus.
	if !isUUIDFormat(pid) {
		httperr.WriteJSON(w, http.StatusOK, map[string]any{"found": false})
		return
	}
	row, found, err := h.Store.RankPointsForPlayer(r.Context(), pid)
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to fetch rank points", err))
		return
	}
	if !found {
		httperr.WriteJSON(w, http.StatusOK, map[string]any{"found": false})
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]any{"found": true, "row": row})
}

// isUUIDFormat — cek format UUID 8-4-4-4-12 heksadesimal tanpa library
// tambahan (go.mod sengaja minimal: pgx + godotenv saja).
func isUUIDFormat(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
			continue
		}
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return true
}

// Player — GET /ratings/players/{playerId} → publik.
func (h *RatingsHandler) Player(w http.ResponseWriter, r *http.Request) {
	pid := r.PathValue("playerId")
	d, err := h.Store.RatingPlayer(r.Context(), pid)
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to fetch player rating", err))
		return
	}
	if d == nil {
		httperr.WriteError(w, h.Logger, httperr.NotFound("player not rated"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, d)
}

// PlayerAchievements — GET /ratings/players/{playerId}/achievements → publik.
func (h *RatingsHandler) PlayerAchievements(w http.ResponseWriter, r *http.Request) {
	pid := r.PathValue("playerId")
	rows, err := h.Store.PlayerAchievements(r.Context(), pid)
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to fetch achievements", err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]any{"achievements": rows})
}

// BackfillAchievements — POST /ratings/achievements/backfill (admin) —
// isi achievement Kelas A dari data historis. Idempoten.
func (h *RatingsHandler) BackfillAchievements(w http.ResponseWriter, r *http.Request) {
	res, err := h.Store.BackfillAchievements(r.Context())
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "achievement backfill failed", err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, res)
}

// Sources — GET /ratings/sources → publik.
func (h *RatingsHandler) Sources(w http.ResponseWriter, r *http.Request) {
	srcs, err := h.Store.ListRatingSources(r.Context())
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to list rating sources", err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]any{"sources": srcs})
}

// atoiSafe — parse int query param dengan fallback yang aman dari integer overflow.
func atoiSafe(s string, fallback int) int {
	if s == "" {
		return fallback
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 {
		return fallback
	}
	return n
}
