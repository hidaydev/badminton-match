package handler

import (
	"context"
	"net/http"
	"time"

	"majadu-api/internal/build"
	"majadu-api/internal/httperr"

	"github.com/jackc/pgx/v5/pgxpool"
)

// HealthHandler — /healthz (liveness) & /readyz (readiness, cek DB).
type HealthHandler struct {
	Pool *pgxpool.Pool
}

// Healthz — liveness: server hidup. Selalu 200.
func (h *HealthHandler) Healthz(w http.ResponseWriter, _ *http.Request) {
	httperr.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// Ready — readiness: DB harus bisa di-ping. 503 kalau tidak.
func (h *HealthHandler) Ready(w http.ResponseWriter, r *http.Request) {
	if h.Pool == nil {
		httperr.WriteError(w, nil, httperr.Unavailable("database not configured"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := h.Pool.Ping(ctx); err != nil {
		httperr.WriteError(w, nil, httperr.Unavailable("database unreachable"))
		return
	}
	httperr.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// Version — informasi build.
func (h *HealthHandler) Version(w http.ResponseWriter, _ *http.Request) {
	httperr.WriteJSON(w, http.StatusOK, map[string]string{
		"version": build.Version,
		"commit":  build.Commit,
		"date":    build.Date,
	})
}
