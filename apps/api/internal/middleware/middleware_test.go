package middleware

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestRequestIDSetsHeaderAndContext(t *testing.T) {
	var got string
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = RequestIDFromContext(r.Context())
		w.WriteHeader(http.StatusOK)
	})
	req := httptest.NewRequest("GET", "/", nil)
	rec := httptest.NewRecorder()
	RequestID(next).ServeHTTP(rec, req)

	if rec.Header().Get("X-Request-ID") == "" {
		t.Fatal("X-Request-ID header not set")
	}
	if got != rec.Header().Get("X-Request-ID") {
		t.Fatalf("context id %q != header %q", got, rec.Header().Get("X-Request-ID"))
	}
}

func TestRequestIDForwardsClientHeader(t *testing.T) {
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	req := httptest.NewRequest("GET", "/", nil)
	req.Header.Set("X-Request-ID", "trace-123")
	rec := httptest.NewRecorder()
	RequestID(next).ServeHTTP(rec, req)
	if rec.Header().Get("X-Request-ID") != "trace-123" {
		t.Fatalf("expected forwarded id, got %q", rec.Header().Get("X-Request-ID"))
	}
}

func TestRateLimitAllowsThenRejects(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	h := RateLimit(ctx, 2, logger)(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "1.2.3.4:1234"
	req.Header.Set("X-Forwarded-For", "1.2.3.4")

	// burst 2: dua request pertama OK
	for i := 0; i < 2; i++ {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("request %d: got %d, want 200", i+1, rec.Code)
		}
	}
	// ketiga: 429
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("expected 429, got %d", rec.Code)
	}
}

func TestRateLimitBucketCleanup(t *testing.T) {
	clock := time.Unix(1_000_000, 0)
	l := &limiter{
		rate:          2.0 / 60,
		burst:         2,
		sweepInterval: time.Minute,
		idleTimeout:   10 * time.Minute,
		maxIPs:        100,
		now:           func() time.Time { return clock },
	}

	// "stale" dibuat lebih dulu, "active" dibuat 2 menit kemudian.
	if !l.allow("stale") {
		t.Fatal("first request from stale should pass")
	}
	clock = clock.Add(2 * time.Minute)
	if !l.allow("active") {
		t.Fatal("first request from active should pass")
	}

	// Majukan waktu 10 menit: stale idle 12m (> 10m), active idle tepat 10m.
	clock = clock.Add(10 * time.Minute)
	l.sweep()

	l.mu.Lock()
	_, staleOK := l.ips["stale"]
	_, activeOK := l.ips["active"]
	l.mu.Unlock()
	if staleOK {
		t.Fatal("stale bucket should be removed by sweep")
	}
	if !activeOK {
		t.Fatal("active bucket should be kept by sweep")
	}

	// IP yang sudah dibersihkan boleh request lagi (bucket baru penuh).
	if !l.allow("stale") {
		t.Fatal("removed IP should be able to rate limit again")
	}
}

func TestRateLimitMapCapEvictsOldestIdle(t *testing.T) {
	clock := time.Unix(1_000_000, 0)
	l := &limiter{
		rate:          2.0 / 60,
		burst:         2,
		sweepInterval: time.Minute,
		idleTimeout:   time.Hour, // nonaktifkan pembersihan idle; hanya cap yang bekerja
		maxIPs:        3,
		now:           func() time.Time { return clock },
	}

	for i := 0; i < 5; i++ {
		if !l.allow(fmt.Sprintf("10.0.0.%d", i)) {
			t.Fatalf("request %d should pass", i)
		}
		clock = clock.Add(time.Minute)
	}
	l.sweep()

	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.ips) != 3 {
		t.Fatalf("len(ips) = %d, want 3", len(l.ips))
	}
	for _, ip := range []string{"10.0.0.0", "10.0.0.1"} {
		if _, ok := l.ips[ip]; ok {
			t.Fatalf("oldest idle IP %s should be evicted", ip)
		}
	}
	for _, ip := range []string{"10.0.0.2", "10.0.0.3", "10.0.0.4"} {
		if _, ok := l.ips[ip]; !ok {
			t.Fatalf("newest IP %s should be kept", ip)
		}
	}
}

func TestClientIPFromXFF(t *testing.T) {
	req := httptest.NewRequest("GET", "/", nil)
	req.Header.Set("X-Forwarded-For", "203.0.113.5, 10.0.0.1")
	if got := clientIP(req); got != "203.0.113.5" {
		t.Fatalf("clientIP = %q, want first XFF entry", got)
	}
}
