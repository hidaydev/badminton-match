package middleware

import (
	"context"
	"encoding/json"
	"log/slog"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

// Konstanta hardening janitor — nilai wajar untuk produksi, tanpa env var
// tambahan. Test memakai nilai kecil dengan mengatur field limiter langsung.
const (
	defaultSweepInterval = 5 * time.Minute
	defaultIdleTimeout   = 10 * time.Minute
	defaultMaxIPs        = 10_000
)

// RateLimit — token bucket per-IP, in-memory (cukup untuk single container;
// perlu shared store hanya jika scale-out). perMinute = 0 → disabled.
// Janitor pembersih bucket idle berjalan sampai ctx dibatalkan.
func RateLimit(ctx context.Context, perMinute int, logger *slog.Logger) func(http.Handler) http.Handler {
	if perMinute <= 0 {
		return func(next http.Handler) http.Handler { return next }
	}
	lm := newLimiter(perMinute, logger)
	lm.start(ctx)
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

	// Parameter janitor. now di-inject supaya test bisa mengatur waktu.
	sweepInterval time.Duration
	idleTimeout   time.Duration
	maxIPs        int
	now           func() time.Time
}

type bucket struct {
	tokens float64
	last   time.Time
}

func newLimiter(perMinute int, logger *slog.Logger) *limiter {
	return &limiter{
		rate:          float64(perMinute) / 60,
		burst:         perMinute,
		logger:        logger,
		sweepInterval: defaultSweepInterval,
		idleTimeout:   defaultIdleTimeout,
		maxIPs:        defaultMaxIPs,
		now:           time.Now,
	}
}

// start menjalankan janitor: tiap sweepInterval hapus bucket yang idle lebih
// dari idleTimeout, lalu usir bucket idle terlama bila map melebihi maxIPs.
// Goroutine berhenti saat ctx dibatalkan.
func (l *limiter) start(ctx context.Context) {
	go func() {
		t := time.NewTicker(l.sweepInterval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				l.sweep()
			}
		}
	}()
}

// sweep menghapus bucket idle, lalu memaksakan batas ukuran map.
func (l *limiter) sweep() {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.ips == nil {
		return
	}
	now := l.now()
	for ip, b := range l.ips {
		if now.Sub(b.last) > l.idleTimeout {
			delete(l.ips, ip)
		}
	}
	if overflow := len(l.ips) - l.maxIPs; overflow > 0 {
		l.evictOldest(overflow)
	}
}

// evictOldest menghapus n bucket dengan aktivitas terlama (dipakai saat map
// overflow). Wajib dipanggil dalam keadaan mu terkunci.
func (l *limiter) evictOldest(n int) {
	if n <= 0 || len(l.ips) == 0 {
		return
	}
	type idleEntry struct {
		ip   string
		last time.Time
	}
	entries := make([]idleEntry, 0, len(l.ips))
	for ip, b := range l.ips {
		entries = append(entries, idleEntry{ip: ip, last: b.last})
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].last.Before(entries[j].last) })
	for i := 0; i < n && i < len(entries); i++ {
		delete(l.ips, entries[i].ip)
	}
}

func (l *limiter) allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.ips == nil {
		l.ips = make(map[string]*bucket)
	}
	now := l.now()
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
