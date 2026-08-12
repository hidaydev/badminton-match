package handler

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"majadu-api/internal/domain"
	"majadu-api/internal/httperr"
	"majadu-api/internal/store"

	"github.com/jackc/pgx/v5/pgconn"
)

// ── error helper ─────────────────────────────────────────────────────────

var (
	errIfMatchMissing   = errors.New("If-Match missing")
	errIfMatchMalformed = errors.New("If-Match malformed")
)

// mapPublishError — mapping error dari publish/delete (pgconn.PgError) ke
// respons yang bersih — jangan bocorkan SQLSTATE / detail internal ke klien.
func mapPublishError(err error) *httperr.Error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		msg := strings.ToLower(pgErr.Message)
		switch {
		case strings.Contains(msg, "locked"):
			return httperr.Conflict("session is locked")
		case strings.Contains(msg, "version mismatch"):
			return httperr.Conflict("version mismatch — reload the latest state and retry")
		case strings.Contains(msg, "not found"):
			return httperr.NotFound("session not found")
		default:
			return httperr.Validation("invalid session state: " + pgErr.Message)
		}
	}
	return httperr.Wrap(httperr.CodeDatabase, "operation failed", err)
}

// SessionHandler — REST endpoints session.
type SessionHandler struct {
	Store  *store.SessionStore
	Logger *slog.Logger
	// BaseURL — URL publik API (untuk header Location), mis. https://api.qouver.com/majadu/v1.
	BaseURL string
}

// ── Types request ────────────────────────────────────────────────────────

type createSessionRequest struct {
	Session    domain.SessionConfig  `json:"session"`
	Players    []domain.Player       `json:"players"`
	FixMatches []domain.FixMatch     `json:"fixMatches"`
	Schedule   []domain.ScheduleSlot `json:"schedule"`
}

type patchSessionRequest struct {
	Title      *string  `json:"title,omitempty"`
	Date       *string  `json:"date,omitempty"`
	CourtNames []string `json:"courtNames,omitempty"`
}

type scoreRequest struct {
	ScoreA int `json:"scoreA"`
	ScoreB int `json:"scoreB"`
}

type renamePlayerRequest struct {
	Name string `json:"name"`
}

type absentRequest struct {
	PlayerIDs []string `json:"playerIds"`
}

type swapRequest struct {
	TargetA json.RawMessage `json:"targetA"`
	TargetB json.RawMessage `json:"targetB"`
}

// ── List & Create ────────────────────────────────────────────────────────

// List — GET /api/sessions.
func (h *SessionHandler) List(w http.ResponseWriter, r *http.Request) {
	metas, err := h.Store.ListSessions(r.Context())
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to list sessions", err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, metas)
}

// Create — POST /api/sessions.
func (h *SessionHandler) Create(w http.ResponseWriter, r *http.Request) {
	var req createSessionRequest
	if err := decodeJSON(r, &req); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body: "+err.Error()))
		return
	}
	if req.Session.Title == "" || len(req.Players) < 4 {
		httperr.WriteError(w, h.Logger, httperr.Validation("session requires title and at least 4 players"))
		return
	}

	// Registrasi pemain (idempotent) — syarat validasi resolve di publish.
	if err := h.Store.EnsurePlayersRegistered(r.Context(), req.Players); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to register players", err))
		return
	}

	// ID sesi di-generate server-side (share_code) — dengan cek exist dulu
	// supaya collision tidak silent-overwrite sesi existing.
	id, err := h.allocateSessionID(r.Context(), w)
	if err != nil {
		httperr.WriteError(w, h.Logger, err)
		return
	}
	snap := &domain.CloudSnapshot{
		Session:     req.Session,
		Players:     req.Players,
		FixMatches:  req.FixMatches,
		Schedule:    req.Schedule,
		PlayedGames: []string{},
		GameScores:  map[string]domain.GameScore{},
	}
	// Invariant dihitung server-side (jangan percaya klien).
	snap.Session.PlayerCount = len(req.Players)
	out, saveErr := h.Store.Save(r.Context(), id, snap)
	if saveErr != nil {
		h.Logger.Warn("create session rejected", "error", saveErr)
		httperr.WriteError(w, h.Logger, mapPublishError(saveErr))
		return
	}
	w.Header().Set("Location", h.location("/sessions/"+id))
	h.writeSession(w, http.StatusCreated, out)
}

// allocateSessionID — generate id unik yang belum dipakai (retry + cek exist).
func (h *SessionHandler) allocateSessionID(ctx context.Context, w http.ResponseWriter) (string, *httperr.Error) {
	const maxTries = 3
	for attempt := 0; ; attempt++ {
		c, err := newShareCode()
		if err != nil {
			return "", httperr.Wrap(httperr.CodeInternal, "failed to generate session id", err)
		}
		_, err = h.Store.Load(ctx, c)
		if errors.Is(err, store.ErrNotFound) {
			return c, nil // id belum dipakai — aman
		}
		if err != nil {
			return "", httperr.Wrap(httperr.CodeDatabase, "failed to check session id", err)
		}
		if attempt >= maxTries {
			return "", httperr.Internal("could not allocate a unique session id")
		}
	}
}

// location — URL absolut resource untuk header Location (fallback relative).
func (h *SessionHandler) location(path string) string {
	if h.BaseURL == "" {
		return path
	}
	return h.BaseURL + path
}

// ── Get, Put, Patch, Delete ───────────────────────────────────────────────

// Get — GET /sessions/{id}.
func (h *SessionHandler) Get(w http.ResponseWriter, r *http.Request) {
	snap, err := h.Store.Load(r.Context(), r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		httperr.WriteError(w, h.Logger, httperr.NotFound("session not found"))
		return
	}
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to load session", err))
		return
	}
	h.writeSession(w, http.StatusOK, snap)
}

// Put — PUT /sessions/{id}: full snapshot replace (create-or-update).
// Kontrak frontend: body = CloudSnapshot lengkap, version dibawa di body
// (atau header If-Match). Ini jembatan integrasi — snapshot persistence.
func (h *SessionHandler) Put(w http.ResponseWriter, r *http.Request) {
	var snap domain.CloudSnapshot
	if err := decodeJSON(r, &snap); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body: "+err.Error()))
		return
	}

	// Version: If-Match lebih disukai; fallback ke version di body
	// (kontrak frontend lama mengirim version dalam snapshot).
	if v, err := versionRequired(r); err == nil {
		snap.Version = &v
	} else if !errors.Is(err, errIfMatchMissing) {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid If-Match header"))
		return
	}

	id := r.PathValue("id")
	// Registrasi pemain (idempotent) — syarat validasi resolve di publish.
	if err := h.Store.EnsurePlayersRegistered(r.Context(), snap.Players); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to register players", err))
		return
	}
	// Invariant dihitung server-side (jangan percaya klien).
	snap.Session.PlayerCount = len(snap.Players)

	out, err := h.Store.Save(r.Context(), id, &snap)
	if err != nil {
		h.Logger.Warn("publish session rejected", "session", id, "error", err)
		httperr.WriteError(w, h.Logger, mapPublishError(err))
		return
	}
	h.writeSession(w, http.StatusOK, out)
}

// Patch — PATCH /api/sessions/{id}: update field metadata.
func (h *SessionHandler) Patch(w http.ResponseWriter, r *http.Request) {
	var req patchSessionRequest
	if err := decodeJSON(r, &req); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body"))
		return
	}
	h.mutate(w, r, func(snap *domain.CloudSnapshot) error {
		if req.Title != nil {
			snap.Session.Title = *req.Title
		}
		if req.Date != nil {
			snap.Session.Date = *req.Date
		}
		if req.CourtNames != nil {
			snap.Session.CourtNames = req.CourtNames
		}
		return nil
	})
}

// Delete — DELETE /sessions/{id}.
func (h *SessionHandler) Delete(w http.ResponseWriter, r *http.Request) {
	if err := h.Store.Delete(r.Context(), r.PathValue("id")); err != nil {
		// delete_session menolak non-draft (locked) — map ke conflict bersih.
		h.Logger.Warn("delete session rejected", "error", err)
		httperr.WriteError(w, h.Logger, mapPublishError(err))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ── Lock / Unlock ───────────────────────────────────────────────────────

func (h *SessionHandler) Lock(w http.ResponseWriter, r *http.Request) {
	h.mutate(w, r, func(snap *domain.CloudSnapshot) error {
		snap.Session.Locked = true
		return nil
	})
}

func (h *SessionHandler) Unlock(w http.ResponseWriter, r *http.Request) {
	h.mutate(w, r, func(snap *domain.CloudSnapshot) error {
		snap.Session.Locked = false
		return nil
	})
}

// ── Games ────────────────────────────────────────────────────────────────

// SetScore — PUT /api/sessions/{id}/games/{gameKey}.
func (h *SessionHandler) SetScore(w http.ResponseWriter, r *http.Request) {
	var req scoreRequest
	if err := decodeJSON(r, &req); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body"))
		return
	}
	h.mutate(w, r, func(snap *domain.CloudSnapshot) error {
		if err := snap.SetScore(r.PathValue("gameKey"), req.ScoreA, req.ScoreB); err != nil {
			return httperr.Validation(err.Error())
		}
		return nil
	})
}

// ClearScore — DELETE /sessions/{id}/games/{gameKey}: hapus skor + un-played.
// Game yang belum played tetap tidak played (bukan toggle).
func (h *SessionHandler) ClearScore(w http.ResponseWriter, r *http.Request) {
	h.mutate(w, r, func(snap *domain.CloudSnapshot) error {
		snap.ClearScore(r.PathValue("gameKey"))
		return nil
	})
}

// ── Players (session-scoped) ─────────────────────────────────────────────

// RenamePlayer — PATCH /api/sessions/{id}/players/{playerId}.
func (h *SessionHandler) RenamePlayer(w http.ResponseWriter, r *http.Request) {
	var req renamePlayerRequest
	if err := decodeJSON(r, &req); err != nil || req.Name == "" {
		httperr.WriteError(w, h.Logger, httperr.Validation("name is required"))
		return
	}
	h.mutate(w, r, func(snap *domain.CloudSnapshot) error {
		snap.RenamePlayer(r.PathValue("playerId"), req.Name)
		return nil
	})
}

// SetAbsent — PUT /api/sessions/{id}/absent.
func (h *SessionHandler) SetAbsent(w http.ResponseWriter, r *http.Request) {
	var req absentRequest
	if err := decodeJSON(r, &req); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body"))
		return
	}
	h.mutate(w, r, func(snap *domain.CloudSnapshot) error {
		snap.SetAbsent(req.PlayerIDs)
		return nil
	})
}

// ── Swaps ────────────────────────────────────────────────────────────────

// SwapPlayers — POST /api/sessions/{id}/swaps/players.
func (h *SessionHandler) SwapPlayers(w http.ResponseWriter, r *http.Request) {
	var req swapRequest
	if err := decodeJSON(r, &req); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body"))
		return
	}
	var t1, t2 domain.SwapTarget
	if err := json.Unmarshal(req.TargetA, &t1); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid targetA"))
		return
	}
	if err := json.Unmarshal(req.TargetB, &t2); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid targetB"))
		return
	}
	if err := t1.Validate(); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid targetA: "+err.Error()))
		return
	}
	if err := t2.Validate(); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid targetB: "+err.Error()))
		return
	}
	h.mutate(w, r, func(snap *domain.CloudSnapshot) error {
		snap.SwapPlayers(t1, t2)
		return nil
	})
}

// SwapTeams — POST /api/sessions/{id}/swaps/teams.
func (h *SessionHandler) SwapTeams(w http.ResponseWriter, r *http.Request) {
	var req swapRequest
	if err := decodeJSON(r, &req); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body"))
		return
	}
	var t1, t2 domain.TeamSwapTarget
	if err := json.Unmarshal(req.TargetA, &t1); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid targetA"))
		return
	}
	if err := json.Unmarshal(req.TargetB, &t2); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid targetB"))
		return
	}
	if err := t1.Validate(); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid targetA: "+err.Error()))
		return
	}
	if err := t2.Validate(); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid targetB: "+err.Error()))
		return
	}
	h.mutate(w, r, func(snap *domain.CloudSnapshot) error {
		snap.SwapTeams(t1, t2)
		return nil
	})
}

// SwapSlots — POST /api/sessions/{id}/swaps/slots.
func (h *SessionHandler) SwapSlots(w http.ResponseWriter, r *http.Request) {
	var req swapRequest
	if err := decodeJSON(r, &req); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body"))
		return
	}
	var g1, g2 domain.SlotSwapTarget
	if err := json.Unmarshal(req.TargetA, &g1); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid targetA"))
		return
	}
	if err := json.Unmarshal(req.TargetB, &g2); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid targetB"))
		return
	}
	if err := g1.Validate(); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid targetA: "+err.Error()))
		return
	}
	if err := g2.Validate(); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid targetB: "+err.Error()))
		return
	}
	h.mutate(w, r, func(snap *domain.CloudSnapshot) error {
		snap.SwapSlots(g1, g2)
		return nil
	})
}

// ── helpers ──────────────────────────────────────────────────────────────

// mutate — pola umum: load → transform → save dengan optimistic concurrency.
// If-Match WAJIB untuk semua mutasi (cegah lost-update antar request).
func (h *SessionHandler) mutate(w http.ResponseWriter, r *http.Request, fn func(*domain.CloudSnapshot) error) {
	id := r.PathValue("id")
	snap, err := h.Store.Load(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		httperr.WriteError(w, h.Logger, httperr.NotFound("session not found"))
		return
	}
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to load session", err))
		return
	}

	// Optimistic concurrency wajib: If-Match "v{n}" = expected version.
	v, err := versionRequired(r)
	switch {
	case errors.Is(err, errIfMatchMissing):
		httperr.WriteError(w, h.Logger, httperr.Precondition("If-Match header is required for mutations"))
		return
	case err != nil:
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid If-Match header"))
		return
	}
	snap.Version = &v

	if err := fn(snap); err != nil {
		httperr.WriteError(w, h.Logger, err)
		return
	}

	out, err := h.Store.Save(r.Context(), id, snap)
	if err != nil {
		// publish_session menolak: lock, version mismatch, validasi.
		h.Logger.Warn("mutation rejected", "session", id, "error", err)
		httperr.WriteError(w, h.Logger, mapPublishError(err))
		return
	}
	h.writeSession(w, http.StatusOK, out)
}

func (h *SessionHandler) writeSession(w http.ResponseWriter, status int, snap *domain.CloudSnapshot) {
	if snap.Version != nil {
		w.Header().Set("ETag", `"v`+strconv.Itoa(*snap.Version)+`"`)
	}
	httperr.WriteJSON(w, status, snap)
}

// versionRequired — parse header If-Match "v{n}". Error jika tidak ada
// (errIfMatchMissing) atau malformed (errIfMatchMalformed).
func versionRequired(r *http.Request) (int, error) {
	v := strings.TrimSpace(r.Header.Get("If-Match"))
	if v == "" {
		return 0, errIfMatchMissing
	}
	v = strings.Trim(v, `"`)
	v = strings.TrimPrefix(v, "v")
	n, err := strconv.Atoi(v)
	if err != nil || n < 1 {
		return 0, errIfMatchMalformed
	}
	return n, nil
}

func decodeJSON(r *http.Request, dst any) error {
	body, err := io.ReadAll(io.LimitReader(r.Body, 10<<20)) // 10 MB guard
	if err != nil {
		return err
	}
	return json.Unmarshal(body, dst)
}

// newShareCode — id sesi pendek acak (share_code). Mengembalikan error kalau
// sumber randomness gagal (fail-fast, bukan fallback deterministik).
func newShareCode() (string, error) {
	s, err := randomAlnum(10)
	if err != nil {
		return "", err
	}
	return "s" + s, nil
}

const alnum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

func randomAlnum(n int) (string, error) {
	rb := make([]byte, n)
	if _, err := rand.Read(rb); err != nil {
		return "", fmt.Errorf("crypto/rand: %w", err)
	}
	b := make([]byte, n)
	for i, rv := range rb {
		b[i] = alnum[int(rv)%len(alnum)]
	}
	return string(b), nil
}
