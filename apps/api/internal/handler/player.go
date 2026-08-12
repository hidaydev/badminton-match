package handler

import (
	"errors"
	"log/slog"
	"net/http"

	"majadu-api/internal/httperr"
	"majadu-api/internal/store"
)

// PlayerHandler — REST endpoints registry pemain.
type PlayerHandler struct {
	Store  *store.PlayerStore
	Logger *slog.Logger
}

type registerPlayerRequest struct {
	Name          string `json:"name"`
	CanonicalName string `json:"canonicalName,omitempty"`
}

// List — GET /api/players.
func (h *PlayerHandler) List(w http.ResponseWriter, r *http.Request) {
	players, err := h.Store.List(r.Context())
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to list players", err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, players)
}

// Register — POST /api/players.
func (h *PlayerHandler) Register(w http.ResponseWriter, r *http.Request) {
	var req registerPlayerRequest
	if err := decodeJSON(r, &req); err != nil || req.Name == "" {
		httperr.WriteError(w, h.Logger, httperr.Validation("name is required"))
		return
	}
	canonical := req.CanonicalName
	if canonical == "" {
		canonical = req.Name
	}
	id, err := h.Store.Register(r.Context(), req.Name, canonical)
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to register player", err))
		return
	}
	httperr.WriteJSON(w, http.StatusCreated, map[string]string{"playerId": id})
}

// Stats — GET /api/players/{name}/stats.
func (h *PlayerHandler) Stats(w http.ResponseWriter, r *http.Request) {
	raw, err := h.Store.Stats(r.Context(), r.PathValue("name"))
	if errors.Is(err, store.ErrNotFound) {
		httperr.WriteError(w, h.Logger, httperr.NotFound("player not found"))
		return
	}
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to load player stats", err))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write(raw)
}
