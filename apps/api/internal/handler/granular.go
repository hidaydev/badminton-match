package handler

import (
	"encoding/json"
	"errors"
	"net/http"

	"majadu-api/internal/httperr"
)

// patchGameRequest — body untuk PATCH /sessions/{id}/games/{key}
type patchGameRequest struct {
	ScoreA   *int  `json:"scoreA"`
	ScoreB   *int  `json:"scoreB"`
	IsPlayed *bool `json:"isPlayed"`
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
	idemKey := r.Header.Get("Idempotency-Key")
	cacheKey := ""
	if idemKey != "" {
		cacheKey = id + ":" + idemKey
		if cached, ok := getIdempotentResponse(cacheKey); ok {
			h.writeSession(w, http.StatusOK, cached)
			return
		}
	}

	var expected *int
	if v, err := versionRequired(r); err == nil {
		expected = &v
	} else if errors.Is(err, errIfMatchMissing) {
		httperr.WriteError(w, h.Logger, httperr.Precondition("If-Match header is required for granular game mutations"))
		return
	} else {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid If-Match header"))
		return
	}

	var out interface{}
	var opErr error
	if req.ScoreA != nil || req.ScoreB != nil {
		if req.ScoreA == nil || req.ScoreB == nil {
			httperr.WriteError(w, h.Logger, httperr.Validation("both scoreA and scoreB are required"))
			return
		}
		if *req.ScoreA < 0 || *req.ScoreA > 99 || *req.ScoreB < 0 || *req.ScoreB > 99 || *req.ScoreA == *req.ScoreB {
			httperr.WriteError(w, h.Logger, httperr.Validation("scores must be 0..99 and not equal"))
			return
		}
		out, opErr = h.Store.SetGameScore(r.Context(), id, gameKey, *req.ScoreA, *req.ScoreB, expected, idemKey)
	} else if req.IsPlayed != nil {
		out, opErr = h.Store.SetGamePlayed(r.Context(), id, gameKey, *req.IsPlayed, expected, idemKey)
	} else {
		httperr.WriteError(w, h.Logger, httperr.Validation("body must contain scoreA/scoreB or isPlayed"))
		return
	}

	if opErr != nil {
		h.Logger.Warn("granular game mutation rejected", "session", id, "gameKey", gameKey, "error", opErr)
		httperr.WriteError(w, h.Logger, mapPublishError(opErr))
		return
	}
	if cacheKey != "" && out != nil {
		// Persisted idempotency already saved in store (after commit); also populate in-memory for next identical request fast path.
		// Use type switch to safely cache only *domain.CloudSnapshot
		if snap, ok := out.(interface{ GetVersion() *int }); ok {
			_ = snap
		}
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

// PatchAbsent — PATCH /sessions/{id}/absent (granular)
func (h *SessionHandler) PatchAbsent(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	var req patchAbsentRequest
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
	out, err := h.Store.SetAbsentPlayers(r.Context(), id, req.PlayerIDs, expected, idemKey)
	if err != nil {
		h.Logger.Warn("granular absent rejected", "session", id, "error", err)
		httperr.WriteError(w, h.Logger, mapPublishError(err))
		return
	}
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
