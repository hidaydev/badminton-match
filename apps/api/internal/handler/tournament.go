package handler

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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
	// AdminStore — SessionStore untuk operasi admin (delete tournament +
	// cleanup rating source). Mirip pola PlayerHandler.
	AdminStore *store.SessionStore
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

// tournamentCreateCache — response create tersimpan untuk replay idempotent.
type tournamentCreateCache struct {
	ID       string          `json:"id"`
	BodyHash string          `json:"bodyHash"`
	Snapshot json.RawMessage `json:"snapshot"`
}

// replayCachedTournament — tulis ulang response create dari cache. Return
// (replayed, mismatch): mismatch=true bila Idempotency-Key dipakai ulang untuk
// body berbeda (caller balas 409, jangan buat tournament baru).
func (h *TournamentHandler) replayCachedTournament(w http.ResponseWriter, format, bodyHash string, body []byte) (bool, bool) {
	var c tournamentCreateCache
	if err := json.Unmarshal(body, &c); err != nil || c.ID == "" {
		return false, false
	}
	if c.BodyHash != "" && c.BodyHash != bodyHash {
		return false, true
	}
	if format == "team" {
		var snap domain.TeamTournamentSnapshot
		if json.Unmarshal(c.Snapshot, &snap) != nil {
			return false, false
		}
		w.Header().Set("Location", h.tournamentLocation(c.ID))
		h.writeTeamTournament(w, http.StatusCreated, &snap)
		return true, false
	}
	var snap domain.TournamentSnapshot
	if json.Unmarshal(c.Snapshot, &snap) != nil {
		return false, false
	}
	w.Header().Set("Location", h.tournamentLocation(c.ID))
	h.writeTournament(w, http.StatusCreated, &snap)
	return true, false
}

func (h *TournamentHandler) tournamentLocation(id string) string {
	loc := "/tournaments/" + id
	if h.BaseURL != "" {
		loc = h.BaseURL + loc
	}
	return loc
}

// Create — POST /tournaments. Format dari body ('classic' default | 'team').
// Idempotency-Key (bila ada) di-replay dari cache 24h supaya retry network
// tidak membuat tournament duplikat (audit 2026-09-12).
func (h *TournamentHandler) Create(w http.ResponseWriter, r *http.Request) {
	body, bodyErr := readBody(r)
	if bodyErr != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body: "+bodyErr.Error()))
		return
	}
	format := probeFormat(body)

	cacheKey := ""
	bodyHash := ""
	if idemKey := r.Header.Get("Idempotency-Key"); idemKey != "" {
		sum := sha256.Sum256(body)
		bodyHash = hex.EncodeToString(sum[:])
		cacheKey = "tournament-create:" + idemKey
		if cached, ok := getIdempotentRaw(cacheKey); ok {
			replayed, mismatch := h.replayCachedTournament(w, format, bodyHash, cached)
			if mismatch {
				httperr.WriteError(w, h.Logger, httperr.Conflict("Idempotency-Key was reused with a different request body"))
				return
			}
			if replayed {
				return
			}
		}
	}

	// allocErr dipisah dari `err` (interface error) — hindari typed-nil gotcha:
	// allocateTournamentID return (*httperr.Error)(nil) saat sukses; kalau di-boxing
	// ke interface error, `!= nil` jadi true → panic.
	id, allocErr := h.allocateTournamentID(r.Context())
	if allocErr != nil {
		httperr.WriteError(w, h.Logger, allocErr)
		return
	}

	switch format {
	case "team":
		var req domain.TeamTournamentSnapshot
		if err := decodeJSONBytes(body, &req); err != nil {
			httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body: "+err.Error()))
			return
		}
		req.Version = nil // server yang menentukan version
		out, saveErr := h.Store.TeamSave(r.Context(), id, &req)
		if saveErr != nil {
			h.Logger.Warn("create team tournament rejected", "error", saveErr)
			httperr.WriteError(w, h.Logger, mapPublishError(saveErr))
			return
		}
		if cacheKey != "" {
			h.cacheTournamentCreate(cacheKey, id, bodyHash, out)
		}
		w.Header().Set("Location", h.tournamentLocation(id))
		h.writeTeamTournament(w, http.StatusCreated, out)
	default:
		var req domain.TournamentSnapshot
		if err := decodeJSONBytes(body, &req); err != nil {
			httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body: "+err.Error()))
			return
		}
		req.Version = nil
		out, saveErr := h.Store.Save(r.Context(), id, &req)
		if saveErr != nil {
			h.Logger.Warn("create tournament rejected", "error", saveErr)
			httperr.WriteError(w, h.Logger, mapPublishError(saveErr))
			return
		}
		if cacheKey != "" {
			h.cacheTournamentCreate(cacheKey, id, bodyHash, out)
		}
		w.Header().Set("Location", h.tournamentLocation(id))
		h.writeTournament(w, http.StatusCreated, out)
	}
}

// cacheTournamentCreate — simpan response create untuk replay idempotent.
func (h *TournamentHandler) cacheTournamentCreate(cacheKey, id, bodyHash string, out any) {
	b, err := json.Marshal(out)
	if err != nil {
		return
	}
	env, err := json.Marshal(tournamentCreateCache{ID: id, BodyHash: bodyHash, Snapshot: b})
	if err != nil {
		return
	}
	setIdempotentRaw(cacheKey, env)
}

// Put — PUT /tournaments/{id}: full snapshot replace (create-or-update).
// Kontrak frontend: body = snapshot lengkap (classic atau team) dengan version.
func (h *TournamentHandler) Put(w http.ResponseWriter, r *http.Request) {
	body, err := readBody(r)
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body: "+err.Error()))
		return
	}
	format := probeFormat(body)
	id := r.PathValue("id")

	// Version: If-Match preferred, fallback ke version di body.
	headerVersion, verErr := versionRequired(r)

	// Format consistency: kalau tournament sudah ada, format harus sama
	// dengan body — cegah convert classic↔team yang bikin data campur aduk.
	existingFormat, existsErr := h.Store.TournamentFormat(r.Context(), id)
	exists := false
	switch {
	case errors.Is(existsErr, store.ErrNotFound):
		exists = false
	case existsErr != nil:
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to check tournament", existsErr))
		return
	default:
		exists = true
		if existingFormat != format {
			httperr.WriteError(w, h.Logger, httperr.Validation(
				fmt.Sprintf("format mismatch: tournament is %q, body is %q", existingFormat, format)))
			return
		}
	}

	switch format {
	case "team":
		var req domain.TeamTournamentSnapshot
		if err := decodeJSONBytes(body, &req); err != nil {
			httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body: "+err.Error()))
			return
		}
		if verErr == nil {
			req.Version = &headerVersion
		} else if !errors.Is(verErr, errIfMatchMissing) {
			httperr.WriteError(w, h.Logger, httperr.Validation("invalid If-Match header"))
			return
		}
		if exists && req.Version == nil {
			httperr.WriteError(w, h.Logger, httperr.Precondition("If-Match (or snapshot version) is required to update an existing tournament"))
			return
		}
		out, err := h.Store.TeamSave(r.Context(), id, &req)
		if err != nil {
			h.Logger.Warn("publish team tournament rejected", "error", err)
			httperr.WriteError(w, h.Logger, mapPublishError(err))
			return
		}
		h.writeTeamTournament(w, http.StatusOK, out)
	default:
		var req domain.TournamentSnapshot
		if err := decodeJSONBytes(body, &req); err != nil {
			httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body: "+err.Error()))
			return
		}
		if verErr == nil {
			req.Version = &headerVersion
		} else if !errors.Is(verErr, errIfMatchMissing) {
			httperr.WriteError(w, h.Logger, httperr.Validation("invalid If-Match header"))
			return
		}
		if exists && req.Version == nil {
			httperr.WriteError(w, h.Logger, httperr.Precondition("If-Match (or snapshot version) is required to update an existing tournament"))
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
	id := r.PathValue("id")
	format, err := h.Store.TournamentFormat(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		httperr.WriteError(w, h.Logger, httperr.NotFound("tournament not found"))
		return
	}
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to load tournament", err))
		return
	}
	if format == "team" {
		snap, err := h.Store.TeamLoad(r.Context(), id)
		if err != nil {
			httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to load team tournament", err))
			return
		}
		h.writeTeamTournament(w, http.StatusOK, snap)
		return
	}
	snap, err := h.Store.Load(r.Context(), id)
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

// DeleteAdmin — POST /tournaments/{id}/delete (admin, AdminGuard): hapus
// tournament (classic | team) + bersihkan rating source + full rebuild.
// Dipakai menu admin / halaman tournament.
func (h *TournamentHandler) DeleteAdmin(w http.ResponseWriter, r *http.Request) {
	share, err := h.AdminStore.AdminDeleteTournament(r.Context(), r.PathValue("id"))
	if err != nil {
		h.Logger.Warn("admin delete tournament rejected", "error", err)
		switch {
		case errors.Is(err, store.ErrNotFound):
			httperr.WriteError(w, h.Logger, httperr.NotFound("tournament not found"))
		case errors.Is(err, store.ErrValidation):
			httperr.WriteError(w, h.Logger, httperr.Validation("invalid tournament id"))
		default:
			httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to delete tournament", err))
		}
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]any{"deleted": true, "tournamentId": share})
}

func (h *TournamentHandler) writeTournament(w http.ResponseWriter, status int, snap *domain.TournamentSnapshot) {
	if snap.Version != nil {
		w.Header().Set("ETag", `"v`+strconv.Itoa(*snap.Version)+`"`)
	}
	httperr.WriteJSON(w, status, snap)
}

func (h *TournamentHandler) writeTeamTournament(w http.ResponseWriter, status int, snap *domain.TeamTournamentSnapshot) {
	if snap.Version != nil {
		w.Header().Set("ETag", `"v`+strconv.Itoa(*snap.Version)+`"`)
	}
	httperr.WriteJSON(w, status, snap)
}

// readBody — baca body (guard ukuran) sekali untuk dipakai double-decode.
func readBody(r *http.Request) ([]byte, error) {
	return io.ReadAll(io.LimitReader(r.Body, 10<<20)) // 10 MB guard
}

// decodeJSONBytes — decode dari bytes yang sudah dibaca.
func decodeJSONBytes(body []byte, dst any) error {
	return json.Unmarshal(body, dst)
}

// probeFormat — baca field `format` dari body tanpa decode penuh.
func probeFormat(body []byte) string {
	var probe struct {
		Format string `json:"format"`
	}
	if err := json.Unmarshal(body, &probe); err != nil {
		return ""
	}
	if probe.Format == "team" {
		return "team"
	}
	return "classic"
}
