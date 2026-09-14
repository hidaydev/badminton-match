package handler

import (
	"crypto/subtle"
	"log/slog"
	"net/http"

	"majadu-api/internal/httperr"
)

// VerifyAdmin — GET /admin/verify (AdminGuard): cek token valid → 200 {ok:true}
func VerifyAdmin(w http.ResponseWriter, r *http.Request) {
	httperr.WriteJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// AdminGuard — middleware admin (Authorization: Bearer MAJADU_ADMIN_TOKEN).
// Dipakai endpoint admin di semua handler.
func AdminGuard(token string, next http.HandlerFunc) http.HandlerFunc {
	return adminGuard(token, nil, next)
}

// adminGuard — implementasi tunggal cek token admin (constant-time compare),
// dipakai AdminGuard (logger nil) dan handler yang punya logger sendiri.
func adminGuard(token string, logger *slog.Logger, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if token == "" {
			httperr.WriteError(w, logger, httperr.Unauthorized("admin token not configured"))
			return
		}
		auth := r.Header.Get("Authorization")
		const prefix = "Bearer "
		if len(auth) < len(prefix) || auth[:len(prefix)] != prefix {
			httperr.WriteError(w, logger, httperr.Unauthorized("missing Bearer token"))
			return
		}
		if subtle.ConstantTimeCompare([]byte(auth[len(prefix):]), []byte(token)) != 1 {
			httperr.WriteError(w, logger, httperr.Unauthorized("invalid admin token"))
			return
		}
		next(w, r)
	}
}
