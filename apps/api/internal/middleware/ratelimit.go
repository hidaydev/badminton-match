package middleware

import (
	"encoding/json"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// RateLimit — token bucket per-IP, in-memory (cukup untuk single container).
// perMinute = 0 → disabled.
func RateLimit(perMinute int, logger *slog.Logger) func(http.Handler) http.Handler {
	if perMinute <= 0 {
		return func(next http.Handler) http.Handler { return next }
	}
	lm := &limiter{
		rate:   float64(perMinute) / 60,
		burst:  perMinute,
		logger: logger,
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ip := clientIP(r)
			if !lm.allow(ip) {
				logger.Warn("rate limited", "ip", ip, "path", r.URL.Path)
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusTooManyRequests)
				_ = json.NewEncoder(w).Encode(map[string]any{
					"error": map[string]string{"code": "rate_limited", "message": "too many requests — slow down"},
				})
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

type limiter struct {
	mu     sync.Mutex
	rate   float64 // token per detik
	burst  int
	logger *slog.Logger
	ips    map[string]*bucket
}

type bucket struct {
	tokens float64
	last   time.Time
}

func (l *limiter) allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.ips == nil {
		l.ips = make(map[string]*bucket)
	}
	now := time.Now()
	b, ok := l.ips[ip]
	if !ok {
		b = &bucket{tokens: float64(l.burst), last: now}
		l.ips[ip] = b
	}
	// refill token berdasarkan waktu yang berlalu, lalu konsumsi 1
	elapsed := now.Sub(b.last).Seconds()
	b.tokens = min(b.tokens+elapsed*l.rate, float64(l.burst))
	b.last = now
	if b.tokens >= 1 {
		b.tokens--
		return true
	}
	return false
}

func clientIP(r *http.Request) string {
	// Caddy reverse_proxy menambah X-Forwarded-For: "client, proxy1, ..."
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		first := strings.TrimSpace(strings.Split(xff, ",")[0])
		if ip := net.ParseIP(first); ip != nil {
			return ip.String()
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
