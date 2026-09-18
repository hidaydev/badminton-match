package handler

import (
	"errors"
	"net/http"
	"strconv"

	"majadu-api/internal/domain"
	"majadu-api/internal/httperr"
)

// MetricsHandler — GET /metrics: counter in-memory granular/contention/deprecated.
func (h *SessionHandler) MetricsHandler(w http.ResponseWriter, r *http.Request) {
	if h.Store == nil || h.Store.Metrics() == nil {
		httperr.WriteJSON(w, http.StatusOK, "# majadu metrics unavailable")
		return
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	w.Write([]byte(h.Store.Metrics().RenderMetrics()))
}

// ListEvents — GET /sessions/{id}/events?since={id}&limit={n}
// Replay outbox (durable SSE recovery). Return []OutboxEvent + nextSince.
func (h *SessionHandler) ListEvents(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	since := int64(0)
	if v := r.URL.Query().Get("since"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			httperr.WriteError(w, h.Logger, httperr.Validation("since must be a non-negative integer"))
			return
		}
		since = n
	}
	limit := 100
	if v := r.URL.Query().Get("limit"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 500 {
			httperr.WriteError(w, h.Logger, httperr.Validation("limit must be 1..500"))
			return
		}
		limit = n
	}
	events, err := h.Store.ListOutboxSince(r.Context(), id, since, limit)
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to list events", err))
		return
	}
	nextSince := since
	if len(events) > 0 {
		nextSince = events[len(events)-1].ID
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]any{
		"events":    events,
		"nextSince": nextSince,
	})
}

// patchGameRequest — body untuk PATCH /sessions/{id}/games/{key}
type patchGameRequest struct {
	ScoreA   *int  `json:"scoreA"`
	ScoreB   *int  `json:"scoreB"`
	IsPlayed *bool `json:"isPlayed"`
}

// requireIfMatch — parse header If-Match "v<n>" untuk mutasi granular. Menulis
// respons 412/400 dan mengembalikan ok=false bila header absen atau malformed.
// requiredMsg adalah pesan precondition saat header absen; tiap endpoint bisa
// berbeda (mis. "... for granular game mutations" vs plain).
func (h *SessionHandler) requireIfMatch(w http.ResponseWriter, r *http.Request, requiredMsg string) (*int, bool) {
	v, err := versionRequired(r)
	switch {
	case err == nil:
		return &v, true
	case errors.Is(err, errIfMatchMissing):
		httperr.WriteError(w, h.Logger, httperr.Precondition(requiredMsg))
	default:
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid If-Match header"))
	}
	return nil, false
}

// replayIdempotent — bila header Idempotency-Key ada, cek cache idempotency
// in-memory. Pada hit: tulis snapshot cached (200) dan kembalikan (snap, true).
func (h *SessionHandler) replayIdempotent(w http.ResponseWriter, r *http.Request, id string) (*domain.CloudSnapshot, bool) {
	idemKey := r.Header.Get("Idempotency-Key")
	if idemKey == "" {
		return nil, false
	}
	cached, ok := getIdempotentResponse(id + ":" + idemKey)
	if !ok {
		return nil, false
	}
	h.writeSession(w, http.StatusOK, cached)
	return cached, true
}

// storeIdempotentResponse — simpan snapshot ke cache idempotency in-memory
// bila header Idempotency-Key ada dan snapshot non-nil. No-op selain itu.
func (h *SessionHandler) storeIdempotentResponse(r *http.Request, id string, snap *domain.CloudSnapshot) {
	if snap == nil {
		return
	}
	idemKey := r.Header.Get("Idempotency-Key")
	if idemKey == "" {
		return
	}
	setIdempotentResponse(id+":"+idemKey, snap)
}

// PatchGame — PATCH /sessions/{id}/games/{gameKey}
// Granular live: score atau played per game, row-level OCC.
func (h *SessionHandler) PatchGame(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	gameKey := r.PathValue("gameKey")
	if gameKey == "" {
		httperr.WriteError(w, h.Logger, httperr.Validation("gameKey is required (format slot-court)"))
		return
	}
	var req patchGameRequest
	if err := decodeJSON(r, &req); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body: "+err.Error()))
		return
	}
	// Idempotency replay SEBELUM If-Match (urutan PatchGame; handler lain
	// memeriksa If-Match lebih dulu). Pertahankan urutan ini.
	if _, hit := h.replayIdempotent(w, r, id); hit {
		return
	}
	expected, ok := h.requireIfMatch(w, r, "If-Match header is required for granular game mutations")
	if !ok {
		return
	}

	var out interface{}
	var opErr error
	if req.ScoreA != nil || req.ScoreB != nil {
		if req.ScoreA == nil || req.ScoreB == nil {
			httperr.WriteError(w, h.Logger, httperr.Validation("both scoreA and scoreB are required"))
			return
		}
		// Aturan skor (0..99, tidak sama) divalidasi store via domain.ValidateScore
		// dan muncul sebagai ErrValidation 400 lewat mapPublishError.
		out, opErr = h.Store.SetGameScore(r.Context(), id, gameKey, *req.ScoreA, *req.ScoreB, expected, r.Header.Get("Idempotency-Key"))
	} else if req.IsPlayed != nil {
		out, opErr = h.Store.SetGamePlayed(r.Context(), id, gameKey, *req.IsPlayed, expected, r.Header.Get("Idempotency-Key"))
	} else {
		httperr.WriteError(w, h.Logger, httperr.Validation("body must contain scoreA/scoreB or isPlayed"))
		return
	}

	if opErr != nil {
		h.Logger.Warn("granular game mutation rejected", "session", id, "gameKey", gameKey, "error", opErr)
		httperr.WriteError(w, h.Logger, mapPublishError(opErr))
		return
	}
	if snap, ok := out.(*domain.CloudSnapshot); ok {
		h.storeIdempotentResponse(r, id, snap)
	}
	h.writeSessionAny(w, http.StatusOK, out)
}

// GetGame — GET /sessions/{id}/games/{gameKey} (granular read: version + score untuk OCC)
func (h *SessionHandler) GetGame(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	gameKey := r.PathValue("gameKey")
	g, err := h.Store.GetGame(r.Context(), id, gameKey)
	if err != nil {
		h.Logger.Warn("get game rejected", "session", id, "gameKey", gameKey, "error", err)
		httperr.WriteError(w, h.Logger, mapPublishError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, g)
}

// patchAbsentRequest — body untuk PATCH /sessions/{id}/absent
type patchAbsentRequest struct {
	PlayerIDs []string `json:"playerIds"`
}

// patchSkipRequest — body untuk PATCH /sessions/{id}/games/{gameKey}/skip
type patchSkipRequest struct {
	PlayerIDs []string `json:"playerIds"`
}

// PatchGameSkipped — PATCH /sessions/{id}/games/{gameKey}/skip (granular per-game skip)
func (h *SessionHandler) PatchGameSkipped(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	gameKey := r.PathValue("gameKey")
	if gameKey == "" {
		httperr.WriteError(w, h.Logger, httperr.Validation("gameKey is required (format slot-court)"))
		return
	}
	var req patchSkipRequest
	if err := decodeJSON(r, &req); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body"))
		return
	}
	expected, ok := h.requireIfMatch(w, r, "If-Match header is required for granular game mutations")
	if !ok {
		return
	}
	if _, hit := h.replayIdempotent(w, r, id); hit {
		return
	}
	// Normalize nil to empty slice (clear skip)
	if req.PlayerIDs == nil {
		req.PlayerIDs = []string{}
	}
	out, err := h.Store.SetGameSkipped(r.Context(), id, gameKey, req.PlayerIDs, expected, r.Header.Get("Idempotency-Key"))
	if err != nil {
		h.Logger.Warn("granular skip rejected", "session", id, "gameKey", gameKey, "error", err)
		httperr.WriteError(w, h.Logger, mapPublishError(err))
		return
	}
	h.storeIdempotentResponse(r, id, out)
	h.writeSession(w, http.StatusOK, out)
}

// PatchAbsent — PATCH /sessions/{id}/absent (granular)
func (h *SessionHandler) PatchAbsent(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req patchAbsentRequest
	if err := decodeJSON(r, &req); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body"))
		return
	}
	expected, ok := h.requireIfMatch(w, r, "If-Match header is required")
	if !ok {
		return
	}
	if _, hit := h.replayIdempotent(w, r, id); hit {
		return
	}
	out, err := h.Store.SetAbsentPlayers(r.Context(), id, req.PlayerIDs, expected, r.Header.Get("Idempotency-Key"))
	if err != nil {
		h.Logger.Warn("granular absent rejected", "session", id, "error", err)
		httperr.WriteError(w, h.Logger, mapPublishError(err))
		return
	}
	h.storeIdempotentResponse(r, id, out)
	h.writeSession(w, http.StatusOK, out)
}

// writeSessionAny — helper untuk write out yang bertipe any (*domain.CloudSnapshot)
func (h *SessionHandler) writeSessionAny(w http.ResponseWriter, status int, snap any) {
	if snap == nil {
		httperr.WriteJSON(w, status, nil)
		return
	}
	httperr.WriteJSON(w, status, snap)
}
