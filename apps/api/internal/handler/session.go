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
	"sync"
	"time"

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

// ── Idempotency (M5 T10) — in-memory, TTL 24h, key = sessionId + Idempotency-Key header ──

var (
	idempotencyMu    sync.Mutex
	idempotencyStore = make(map[string]idempotencyEntry)
)

type idempotencyEntry struct {
	snap   *domain.CloudSnapshot
	expiry time.Time
}

func getIdempotentResponse(key string) (*domain.CloudSnapshot, bool) {
	idempotencyMu.Lock()
	defer idempotencyMu.Unlock()
	e, ok := idempotencyStore[key]
	if !ok {
		return nil, false
	}
	if time.Now().After(e.expiry) {
		delete(idempotencyStore, key)
		return nil, false
	}
	return e.snap, true
}

func setIdempotentResponse(key string, snap *domain.CloudSnapshot) {
	idempotencyMu.Lock()
	defer idempotencyMu.Unlock()
	// Clean expired (lazy, cap 1000)
	if len(idempotencyStore) >= 1000 {
		now := time.Now()
		for k, v := range idempotencyStore {
			if now.After(v.expiry) {
				delete(idempotencyStore, k)
			}
		}
		// Hard cap eviction: evict oldest if still >= 1000
		if len(idempotencyStore) >= 1000 {
			var oldestKey string
			var oldestExp time.Time
			for k, v := range idempotencyStore {
				if oldestKey == "" || v.expiry.Before(oldestExp) {
					oldestKey = k
					oldestExp = v.expiry
				}
			}
			if oldestKey != "" {
				delete(idempotencyStore, oldestKey)
			}
		}
	}
	idempotencyStore[key] = idempotencyEntry{snap: snap, expiry: time.Now().Add(24 * time.Hour)}
}

// mapPublishError — mapping error dari publish/delete (sentinels store atau
// pgconn.PgError) ke respons yang bersih — jangan bocorkan SQLSTATE / detail
// internal ke klien. Pesan mempertahankan substring yang dibaca frontend
// (isVersionMismatch / getSaveErrorMessage di src/queries/errors.ts).
func mapPublishError(err error) *httperr.Error {
	switch {
	case errors.Is(err, store.ErrNotFound):
		return httperr.NotFound("session not found")
	case errors.Is(err, store.ErrLocked):
		return httperr.Conflict("session is locked")
	case errors.Is(err, store.ErrVersionMismatch):
		return httperr.Conflict("version mismatch — reload the latest state and retry")
	case errors.Is(err, store.ErrContention):
		return httperr.TooManyRequests("session is being updated by another request; retry after 1s")
	case errors.Is(err, store.ErrValidation):
		return httperr.Validation("invalid session state: " + err.Error())
	}
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
	BaseURL    string
	AdminToken string
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

// Watch — GET /sessions/{id}/watch SSE full snapshot (realtime-ness, M5-C).
// Tanpa AdminGuard (read anon, sama seperti Get). Kirim snapshot awal lalu tiap Broadcast.
func (h *SessionHandler) Watch(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	// Subscribe DULU sebelum Load — eliminasi TOCTOU race: Broadcast yang terjadi
	// antara Load dan Subscribe sekarang masuk ke buffered channel dan dikirim di
	// iterasi pertama loop (tidak ada update yang hilang).
	ch, cancel := h.Store.Subscribe(id)
	defer cancel()
	snap, err := h.Store.Load(r.Context(), id)
	if errors.Is(err, store.ErrNotFound) {
		httperr.WriteError(w, h.Logger, httperr.NotFound("session not found"))
		return
	}
	if err != nil {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to load session", err))
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	// CORS untuk EventSource (Browser kirim Accept: text/event-stream)
	w.Header().Set("Access-Control-Allow-Origin", "*")
	rc := http.NewResponseController(w)
	// Kirim snapshot awal segera (realtime-ness, 0 GET)
	data, _ := json.Marshal(snap)
	if _, err := fmt.Fprintf(w, "data: %s\n\n", data); err != nil {
		return
	}
	_ = rc.Flush()
	for {
		select {
		case <-r.Context().Done():
			return
		case s, ok := <-ch:
			if !ok {
				return
			}
			data, _ := json.Marshal(s)
			if _, err := fmt.Fprintf(w, "data: %s\n\n", data); err != nil {
				return
			}
			_ = rc.Flush()
		}
	}
}

// Put — PUT /sessions/{id}: full snapshot replace (create-or-update).
// Kontrak frontend: body = CloudSnapshot lengkap, version dibawa di body
// (atau header If-Match). Aturan:
//   - sesi BELUM ada  → create (tanpa version boleh)
//   - sesi SUDAH ada  → WAJIB version (If-Match atau body.version),
//     tolak update tanpa version (cegah silent-overwrite).
func (h *SessionHandler) Put(w http.ResponseWriter, r *http.Request) {
	// Clean break (grand-revamp): PUT snapshot adalah kontrak legacy — live ops
	// wajib granular (PATCH /games/{key}, PATCH /absent). PUT tetap berfungsi
	// hanya untuk fase setup/generate + operasi swap yang belum granular.
	// Client baru diarahkan ke granular; deprecation header untuk observability.
	w.Header().Set("X-Snapshot-Deprecated", "true")
	if h.Store != nil && h.Store.Metrics() != nil {
		h.Store.Metrics().SnapshotPuts.Add(1)
	}
	if h.Logger != nil {
		h.Logger.Warn("PUT /sessions/{id} deprecated for live ops — use PATCH granular",
			"session", r.PathValue("id"), "remote", r.RemoteAddr)
	}

	var snap domain.CloudSnapshot
	if err := decodeJSON(r, &snap); err != nil {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid JSON body: "+err.Error()))
		return
	}

	// Version: If-Match lebih disukai; fallback ke version di body
	// (kontrak frontend lama mengirim version dalam snapshot).
	// Setelah M2 FE sudah kirim If-Match header, body fallback dipertahankan 1 rilis untuk compat.
	version, versionErr := versionRequired(r)
	if versionErr == nil {
		snap.Version = &version
	} else if !errors.Is(versionErr, errIfMatchMissing) {
		httperr.WriteError(w, h.Logger, httperr.Validation("invalid If-Match header"))
		return
	} else if snap.Version != nil {
		// Header missing tapi body bawa version — compat, log warn untuk observability
		if h.Logger != nil {
			h.Logger.Warn("PUT without If-Match, using body version", "session", r.PathValue("id"), "version", *snap.Version)
		}
	}

	id := r.PathValue("id")
	// Idempotency: jika header ada dan sudah pernah sukses, kembalikan cache tanpa re-execute (network retry)
	idempotencyKey := r.Header.Get("Idempotency-Key")
	cacheKey := ""
	if idempotencyKey != "" {
		cacheKey = id + ":" + idempotencyKey
		if cached, ok := getIdempotentResponse(cacheKey); ok {
			h.writeSession(w, http.StatusOK, cached)
			return
		}
	}
	// Update (sesi sudah ada) tanpa version = berbahaya → tolak.
	if _, err := h.Store.Load(r.Context(), id); err == nil {
		if snap.Version == nil {
			httperr.WriteError(w, h.Logger, httperr.Precondition("If-Match (or snapshot version) is required to update an existing session"))
			return
		}
	} else if !errors.Is(err, store.ErrNotFound) {
		httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to check session", err))
		return
	}

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
	if cacheKey != "" {
		setIdempotentResponse(cacheKey, out)
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

// DeleteAdmin — POST /sessions/{id}/delete (admin, AdminGuard): hapus sesi
// status apa pun (locked termasuk) + bersihkan rating source + full rebuild.
// Dipakai menu admin (ADMIN_MENU_PLAN).
func (h *SessionHandler) DeleteAdmin(w http.ResponseWriter, r *http.Request) {
	share, err := h.Store.AdminDeleteSession(r.Context(), r.PathValue("id"))
	if err != nil {
		h.Logger.Warn("admin delete session rejected", "error", err)
		httperr.WriteError(w, h.Logger, mapPublishError(err))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]any{"deleted": true, "sessionId": share})
}

// ── Lock / Unlock ───────────────────────────────────────────────────────

// Lock — POST /sessions/{id}/lock: kunci sesi (cegah mutasi lebih lanjut).
func (h *SessionHandler) Lock(w http.ResponseWriter, r *http.Request) {
	h.mutate(w, r, func(snap *domain.CloudSnapshot) error {
		snap.Session.Locked = true
		return nil
	})
}

// Unlock — POST /sessions/{id}/unlock: buka kunci sesi. Tanpa If-Match
// (mirror unlock_session SQL) — status → draft, version +1.
func (h *SessionHandler) Unlock(w http.ResponseWriter, r *http.Request) {
	out, err := h.Store.Unlock(r.Context(), r.PathValue("id"))
	if err != nil {
		switch {
		case errors.Is(err, store.ErrNotFound):
			httperr.WriteError(w, h.Logger, httperr.NotFound("session not found"))
		case errors.Is(err, store.ErrContention):
			httperr.WriteError(w, h.Logger, httperr.TooManyRequests("session is being updated by another request; retry after 1s"))
		default:
			h.Logger.Warn("unlock session failed", "session", r.PathValue("id"), "error", err)
			httperr.WriteError(w, h.Logger, httperr.Wrap(httperr.CodeDatabase, "failed to unlock session", err))
		}
		return
	}
	h.writeSession(w, http.StatusOK, out)
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
