package handler

import (
	"encoding/json"
	"errors"
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body"))
		return
	}
	var expected *int
	if v, err := versionRequired(r); err == nil {
		expected = &v
	} else if errors.Is(err, errIfMatchMissing) {
		httperr.WriteError(w, h.Logger, httperr.Precondition("If-Match header is required"))
		return
	} else {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid If-Match header"))
		return
	}
	idemKey := r.Header.Get("Idempotency-Key")
	cacheKey := ""
	if idemKey != "" {
		cacheKey = id + ":" + idemKey
		if cached, ok := getIdempotentResponse(cacheKey); ok {
			h.writeSession(w, http.StatusOK, cached)
			return
		}
	}
	out, err := h.Store.SwapMembers(r.Context(), id, req.Type, req.A, req.B, expected, idemKey)
	if err != nil {
		h.Logger.Warn("granular swap rejected", "session", id, "type", req.Type, "error", err)
		httperr.WriteError(w, h.Logger, mapPublishError(err))
		return
	}
	h.writeSession(w, http.StatusOK, out)
}
