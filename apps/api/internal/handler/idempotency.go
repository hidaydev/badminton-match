package handler

import (
	"encoding/json"
	"sync"
	"time"

	"majadu-api/internal/domain"
)

// IdempotencyCache — cache respons in-memory untuk replay request yang sama
// (header Idempotency-Key). TTL 24 jam, kapasitas lunak 1000 dengan eviction.
//
// CATATAN: state ini per-proses. Kalau kelak API dijalankan multi-container
// tanpa sticky session, replay bisa lolos ke instance lain. Store juga punya
// dedup idempotency berbasis DB (rating/outbox); cache ini hanya fast-path
// untuk menghindari kerja ulang, bukan jaminan lintas-proses.
type IdempotencyCache struct {
	mu      sync.Mutex
	entries map[string]idempotencyEntry
}

type idempotencyEntry struct {
	body   []byte
	expiry time.Time
}

// defaultIdempotencyCache dipakai bila handler tidak di-inject cache sendiri.
// Ini menjaga kompatibilitas konstruksi handler yang ada (termasuk test).
var defaultIdempotencyCache = &IdempotencyCache{entries: make(map[string]idempotencyEntry)}

// NewIdempotencyCache — cache kosong untuk di-inject ke handler.
func NewIdempotencyCache() *IdempotencyCache {
	return &IdempotencyCache{entries: make(map[string]idempotencyEntry)}
}

func (c *IdempotencyCache) getRaw(key string) ([]byte, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[key]
	if !ok {
		return nil, false
	}
	if time.Now().After(e.expiry) {
		delete(c.entries, key)
		return nil, false
	}
	return append([]byte(nil), e.body...), true
}

func (c *IdempotencyCache) setRaw(key string, body []byte) {
	if len(body) == 0 {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	// Clean expired (lazy, cap 1000)
	if len(c.entries) >= 1000 {
		now := time.Now()
		for k, v := range c.entries {
			if now.After(v.expiry) {
				delete(c.entries, k)
			}
		}
		// Hard cap eviction: evict oldest if still >= 1000
		if len(c.entries) >= 1000 {
			var oldestKey string
			var oldestExp time.Time
			for k, v := range c.entries {
				if oldestKey == "" || v.expiry.Before(oldestExp) {
					oldestKey = k
					oldestExp = v.expiry
				}
			}
			if oldestKey != "" {
				delete(c.entries, oldestKey)
			}
		}
	}
	c.entries[key] = idempotencyEntry{body: append([]byte(nil), body...), expiry: time.Now().Add(24 * time.Hour)}
}

// getResponse — decode snapshot cached untuk key.
func (c *IdempotencyCache) getResponse(key string) (*domain.CloudSnapshot, bool) {
	b, ok := c.getRaw(key)
	if !ok {
		return nil, false
	}
	var snap domain.CloudSnapshot
	if err := json.Unmarshal(b, &snap); err != nil {
		return nil, false
	}
	return &snap, true
}

// setResponse — simpan snapshot sebagai JSON untuk key.
func (c *IdempotencyCache) setResponse(key string, snap *domain.CloudSnapshot) {
	if snap == nil {
		return
	}
	b, err := json.Marshal(snap)
	if err != nil {
		return
	}
	c.setRaw(key, b)
}

// ── Resolusi cache per-handler (fallback ke default) ────────────────────────

func (h *SessionHandler) idempotency() *IdempotencyCache {
	if h.Idem != nil {
		return h.Idem
	}
	return defaultIdempotencyCache
}

func (h *TournamentHandler) idempotency() *IdempotencyCache {
	if h.Idem != nil {
		return h.Idem
	}
	return defaultIdempotencyCache
}
