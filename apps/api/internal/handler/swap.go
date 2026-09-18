package handler

import (
	"net/http"

	"majadu-api/internal/httperr"
	"majadu-api/internal/store"
)

// swapRequest — body POST /sessions/{id}/swap (granular).
// a/b adalah SwapTarget (mirror FE). Type: player | team | slot.
type swapRequest struct {
	Type string           `json:"type"`
	A    store.SwapTarget `json:"a"`
	B    store.SwapTarget `json:"b"`
}

// SwapMembers — POST /sessions/{id}/swap (granular, session-level OCC).
func (h *SessionHandler) SwapMembers(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req swapRequest
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
	out, err := h.Store.SwapMembers(r.Context(), id, req.Type, req.A, req.B, expected, r.Header.Get("Idempotency-Key"))
	if err != nil {
		h.Logger.Warn("granular swap rejected", "session", id, "type", req.Type, "error", err)
		httperr.WriteError(w, h.Logger, mapPublishError(err))
		return
	}
	h.writeSession(w, http.StatusOK, out)
}
