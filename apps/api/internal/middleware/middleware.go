package middleware

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"time"
)

// Logging mencatat method, path, status, durasi via slog.
func Logging(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(rec, r)
			logger.Info("request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", rec.status,
				"duration_ms", time.Since(start).Milliseconds(),
			)
		})
	}
}

// statusRecorder — membungkus ResponseWriter untuk menangkap status code.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

// Recover menangkap panic → 500 JSON (bukan crash, bukan text/plain).
func Recover(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer func() {
				if rec := recover(); rec != nil {
					logger.Error("panic recovered", "panic", rec, "path", r.URL.Path)
					w.Header().Set("Content-Type", "application/json")
					w.WriteHeader(http.StatusInternalServerError)
					_ = json.NewEncoder(w).Encode(map[string]any{
						"error": map[string]string{"code": "internal", "message": "internal error"},
					})
				}
			}()
			next.ServeHTTP(w, r)
		})
	}
}

// CORS — izinkan origin frontend (Vercel) memanggil API dari subdomain berbeda.
// allowed = daftar origin eksplisit, atau ["*"] untuk dev.
func CORS(allowed []string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			origin := r.Header.Get("Origin")
			if origin != "" && originAllowed(origin, allowed) {
				h := w.Header()
				h.Set("Access-Control-Allow-Origin", origin)
				h.Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
				h.Set("Access-Control-Allow-Headers", "Content-Type, If-Match, ETag")
				h.Add("Vary", "Origin")
			}
			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// originAllowed — pencocokan origin dengan dukungan wildcard subdomain
// (mis. "https://*.vercel.app" cocok dengan "https://foo.vercel.app").
func originAllowed(origin string, allowed []string) bool {
	originHost := hostOf(origin)
	for _, a := range allowed {
		if a == "*" || a == origin {
			return true
		}
		host := hostOf(a)
		if strings.HasPrefix(host, "*.") {
			domain := strings.TrimPrefix(host, "*.")
			if originHost == domain || strings.HasSuffix(originHost, "."+domain) {
				return true
			}
		}
	}
	return false
}

// hostOf — potong scheme dari origin/allowlist, sisakan host saja.
func hostOf(s string) string {
	if i := strings.Index(s, "://"); i >= 0 {
		return s[i+3:]
	}
	return s
}
