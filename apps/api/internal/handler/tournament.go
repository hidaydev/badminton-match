package handler

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strconv"

	"majadu-api/internal/domain"
	"majadu-api/internal/httperr"
	"majadu-api/internal/store"
)

// TournamentHandler — REST endpoints tournament.
type TournamentHandler struct {
	Store  *store.TournamentStore
	Logger *slog.Logger
	// BaseURL — URL publik API (untuk header Location).
	BaseURL string
}

// List — GET /tournaments: metadata semua tournament (terbaru dulu).
func (h *TournamentHandler) List(w http.ResponseWriter, r *http.Request) {
	metas, err := h.Store.List(r.Context())
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to list tournaments", err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, metas)
}

// Create — POST /tournaments.
func (h *TournamentHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req domain.TournamentSnapshot
	if err := decodeJSON(r, &req); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body: "+err.Error()))
		return
	}
	// Server yang menentukan version & id — jangan percaya klien.
	req.Version = nil

	id, err := h.allocateTournamentID(r.Context())
	if err != nil {
		httperr.WriteError(w, h.Logger, err)
		return
	}

	out, saveErr := h.Store.Save(r.Context(), id, &req)
	if saveErr != nil {
		// Validasi 16 pairs / 4 groups / 32 matches dst ditolak publish.
		h.Logger.Warn("create tournament rejected", "error", saveErr)
		httperr.WriteError(w, h.Logger, mapPublishError(saveErr))
		return
	}
	loc := "/tournaments/" + id
	if h.BaseURL != "" {
		loc = h.BaseURL + loc
	}
	w.Header().Set("Location", loc)
	h.writeTournament(w, http.StatusCreated, out)
}

// Put — PUT /tournaments/{id}: full snapshot replace (create-or-update).
// Kontrak frontend lama: body = TournamentSnapshot lengkap dengan version.
// Update (sudah ada) wajib version — cegah silent-overwrite.
func (h *TournamentHandler) Put(w http.ResponseWriter, r *http.Request) {
	var req domain.TournamentSnapshot
	if err := decodeJSON(r, &req); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body: "+err.Error()))
		return
	}

	// Version: If-Match preferred, fallback ke version di body.
	if v, err := versionRequired(r); err == nil {
		req.Version = &v
	} else if !errors.Is(err, errIfMatchMissing) {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid If-Match header"))
		return
	}

	id := r.PathValue("id")
	if _, err := h.Store.Load(r.Context(), id); err == nil {
		if req.Version == nil {
			httperr.WriteError(w, h.Logger, httperr.Precondition("If-Match (or snapshot version) is required to update an existing tournament"))
			return
		}
	} else if !errors.Is(err, store.ErrNotFound) {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to check tournament", err))
		return
	}

	out, err := h.Store.Save(r.Context(), id, &req)
	if err != nil {
		h.Logger.Warn("publish tournament rejected", "error", err)
		httperr.WriteError(w, h.Logger, mapPublishError(err))
		return
	}
	h.writeTournament(w, http.StatusOK, out)
}

// allocateTournamentID — generate id unik (cegah silent-overwrite via upsert).
func (h *TournamentHandler) allocateTournamentID(ctx context.Context) (string, *httperr.Error) {
	const maxTries = 3
	for attempt := 0; ; attempt++ {
		c, err := newShareCode()
		if err != nil {
			return "", httperr.Wrap(httperr.CodeInternal, "failed to generate tournament id", err)
		}
		_, err = h.Store.Load(ctx, c)
		if errors.Is(err, store.ErrNotFound) {
			return c, nil
		}
		if err != nil {
			return "", httperr.Wrap(httperr.CodeDatabase, "failed to check tournament id", err)
		}
		if attempt >= maxTries {
			return "", httperr.Internal("could not allocate a unique tournament id")
		}
	}
}

// Get — GET /api/tournaments/{id}.
func (h *TournamentHandler) Get(w http.ResponseWriter, r *http.Request) {
	snap, err := h.Store.Load(r.Context(), r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		httperr.WriteError(w, h.Logger, httperr.NotFound("tournament not found"))
		return
	}
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to load tournament", err))
		return
	}
	h.writeTournament(w, http.StatusOK, snap)
}

// Patch — PATCH /tournaments/{id}: update (skor/bracket), full replace
// dengan optimistic concurrency via If-Match (wajib).
func (h *TournamentHandler) Patch(w http.ResponseWriter, r *http.Request) {
	var req domain.TournamentSnapshot
	if err := decodeJSON(r, &req); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body"))
		return
	}

	id := r.PathValue("id")
	// Validasi awal: tournament harus sudah ada.
	if _, err := h.Store.Load(r.Context(), id); err != nil {
		httperr.WriteError(w, h.Logger, httperr.NotFound("tournament not found"))
		return
	}

	v, err := versionRequired(r)
	switch {
	case errors.Is(err, errIfMatchMissing):
		httperr.WriteError(w, h.Logger, httperr.Precondition("If-Match header is required for mutations"))
		return
	case err != nil:
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid If-Match header"))
		return
	}
	req.Version = &v

	out, err := h.Store.Save(r.Context(), id, &req)
	if err != nil {
		h.Logger.Warn("update tournament rejected", "error", err)
		httperr.WriteError(w, h.Logger, mapPublishError(err))
		return
	}
	h.writeTournament(w, http.StatusOK, out)
}

func (h *TournamentHandler) writeTournament(w http.ResponseWriter, status int, snap *domain.TournamentSnapshot) {
	if snap.Version != nil {
		w.Header().Set("ETag", `"v`+strconv.Itoa(*snap.Version)+`"`)
	}
	httperr.WriteJSON(w, status, snap)
}
