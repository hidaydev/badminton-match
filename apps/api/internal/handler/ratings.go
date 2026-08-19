package handler

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"net/http"

	"majadu-api/internal/httperr"
	"majadu-api/internal/store"
)

// ── Rating handler (RATING_ENGINE_DESIGN.md §6) ───────────────────────────
// Write endpoints admin-only (MAJADU_ADMIN_TOKEN). Read endpoints publik.

// RatingsHandler — HTTP handlers untuk rating engine.
type RatingsHandler struct {
	Store *store.SessionStore
	// AdminToken — token admin (Authorization: Bearer). Kosong = semua
	// endpoint admin ditolak 401.
	AdminToken string
}

// RequireAdmin — middleware admin (Authorization: Bearer MAJADU_ADMIN_TOKEN).
func (h *RatingsHandler) RequireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return h.requireAdmin(next)
}

// requireAdmin — middleware sederhana untuk endpoint write ratings.
func (h *RatingsHandler) requireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if h.AdminToken == "" {
			httperr.WriteError(w, nil, httperr.Unauthorized("admin token not configured"))
			return
		}
		auth := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if len(auth) < len(prefix) || auth[:len(prefix)] != prefix {
			httperr.WriteError(w, nil, httperr.Unauthorized("missing Bearer token"))
			return
		}
		token := auth[len(prefix):]
		if subtle.ConstantTimeCompare([]byte(token), []byte(h.AdminToken)) != 1 {
			httperr.WriteError(w, nil, httperr.Unauthorized("invalid admin token"))
			return
		}
		next(w, r)
	}
}

// body struct — request ingest/revert/finalize.
type ratingBody struct {
	SessionID    string `json:"sessionId"`
	TournamentID string `json:"tournamentId"`
	SourceID     string `json:"sourceId"`
	Finalized    *bool  `json:"finalized"`
}

// mapRatingError — sentinel store → httperr (design §6 error contract).
func mapRatingError(err error) *httperr.Error {
	switch {
	case errors.Is(err, store.ErrSourceNotFound):
		return httperr.NotFound(err.Error())
	case errors.Is(err, store.ErrSourceChanged):
		return httperr.SourceChanged(err.Error())
	case errors.Is(err, store.ErrOutOfOrder):
		return httperr.Conflict(err.Error())
	case errors.Is(err, store.ErrSourceNotFinal):
		return httperr.Conflict(err.Error())
	default:
		return httperr.Internal(err.Error())
	}
}

// IngestSession — POST /ratings/ingest-session {sessionId} → 200 IngestResult.
func (h *RatingsHandler) IngestSession(w http.ResponseWriter, r *http.Request) {
	var body ratingBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.SessionID == "" {
		httperr.WriteError(w, nil, httperr.Validation("sessionId is required"))
		return
	}
	res, err := h.Store.IngestSession(r.Context(), body.SessionID)
	if err != nil {
		httperr.WriteError(w, nil, mapRatingError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, res)
}

// IngestTournament — POST /ratings/ingest-tournament {tournamentId} → 200.
func (h *RatingsHandler) IngestTournament(w http.ResponseWriter, r *http.Request) {
	var body ratingBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.TournamentID == "" {
		httperr.WriteError(w, nil, httperr.Validation("tournamentId is required"))
		return
	}
	res, err := h.Store.IngestTournament(r.Context(), body.TournamentID)
	if err != nil {
		httperr.WriteError(w, nil, mapRatingError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, res)
}

// RevertSession — POST /ratings/revert-session {sessionId} → full rebuild.
func (h *RatingsHandler) RevertSession(w http.ResponseWriter, r *http.Request) {
	var body ratingBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.SessionID == "" {
		httperr.WriteError(w, nil, httperr.Validation("sessionId is required"))
		return
	}
	res, err := h.Store.RevertSource(r.Context(), body.SessionID, "session")
	if err != nil {
		httperr.WriteError(w, nil, mapRatingError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, res)
}

// RevertTournament — POST /ratings/revert-tournament {tournamentId}.
func (h *RatingsHandler) RevertTournament(w http.ResponseWriter, r *http.Request) {
	var body ratingBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.TournamentID == "" {
		httperr.WriteError(w, nil, httperr.Validation("tournamentId is required"))
		return
	}
	res, err := h.Store.RevertSource(r.Context(), body.TournamentID, "tournament")
	if err != nil {
		httperr.WriteError(w, nil, mapRatingError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, res)
}

// FinalizeSource — POST /ratings/sources/{sourceId}/finalize {finalized}.
func (h *RatingsHandler) FinalizeSource(w http.ResponseWriter, r *http.Request) {
	sourceID := r.PathValue("sourceId")
	var body ratingBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		httperr.WriteError(w, nil, httperr.Validation("finalized is required"))
		return
	}
	if body.Finalized == nil {
		httperr.WriteError(w, nil, httperr.Validation("finalized is required"))
		return
	}
	err := h.Store.SetSourceFinalized(r.Context(), sourceID, *body.Finalized)
	if err != nil {
		httperr.WriteError(w, nil, mapRatingError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// RebuildAll — POST /ratings/rebuild-all (admin) — full rebuild dari events
// tersisa (tool tuning config).
func (h *RatingsHandler) RebuildAll(w http.ResponseWriter, r *http.Request) {
	n, err := h.Store.RebuildAll(r.Context())
	if err != nil {
		httperr.WriteError(w, nil, mapRatingError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]int{"rebuilt": n})
}

// Leaderboard — GET /ratings/leaderboard?active&limit&offset → publik.
func (h *RatingsHandler) Leaderboard(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	active := q.Get("active") == "true"
	limit := atoiSafe(q.Get("limit"), 100)
	offset := atoiSafe(q.Get("offset"), 0)
	total, rows, err := h.Store.RatingLeaderboard(r.Context(), active, limit, offset)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal(err.Error()))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]any{
		"total": total,
		"rows":  rows,
	})
}

// Player — GET /ratings/players/{playerId} → publik.
func (h *RatingsHandler) Player(w http.ResponseWriter, r *http.Request) {
	pid := r.PathValue("playerId")
	d, err := h.Store.RatingPlayer(r.Context(), pid)
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal(err.Error()))
		return
	}
	if d == nil {
		httperr.WriteError(w, nil, httperr.NotFound("player not rated"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, d)
}

// Sources — GET /ratings/sources → publik.
func (h *RatingsHandler) Sources(w http.ResponseWriter, r *http.Request) {
	srcs, err := h.Store.ListRatingSources(r.Context())
	if err != nil {
		httperr.WriteError(w, nil, httperr.Internal(err.Error()))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]any{"sources": srcs})
}

// atoiSafe — parse int query param dengan fallback.
func atoiSafe(s string, fallback int) int {
	if s == "" {
		return fallback
	}
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return fallback
		}
		n = n*10 + int(c-'0')
	}
	if n < 0 {
		return fallback
	}
	return n
}
