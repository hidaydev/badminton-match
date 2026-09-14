// Package store — akses data. Write-path session (publish/delete/unlock)
// dijalankan langsung di Go dalam satu transaksi; read-path session/player
// juga di Go (rebuild snapshot dari tabel relasional).
package store

import (
	"errors"
	"log/slog"
	"sync"

	"majadu-api/internal/domain"

	"github.com/jackc/pgx/v5/pgxpool"
)

// ── Error sentinel ─────────────────────────────────────────────────────────
// Dipetakan ke respons HTTP oleh handler (lihat mapPublishError) — kontrak
// publik error tidak berubah dibanding era fungsi SQL.
var (
	// ErrNotFound — resource tidak ada.
	ErrNotFound = errors.New("not found")
	// ErrLocked — session berstatus non-draft (locked/completed/archived).
	ErrLocked = errors.New("session is locked")
	// ErrVersionMismatch — expected version tidak cocok dengan versi tersimpan.
	ErrVersionMismatch = errors.New("version mismatch")
	// ErrValidation — snapshot gagal validasi / resolve pemain.
	ErrValidation = errors.New("validation failed")
	// ErrContention — sesi sedang di-update request lain (advisory lock / FOR UPDATE NOWAIT).
	ErrContention = errors.New("session is being updated by another request; reload and retry")
)

// SessionStore — akses session.
type SessionStore struct {
	pool *pgxpool.Pool
	// schema — nama schema aktif (MAJADU_DB_SCHEMA: bm / bm_dev). Dipakai
	// sebagai namespace kunci advisory lock mengikuti konvensi per-env.
	schema   string
	mu       sync.RWMutex
	watchers map[string]map[chan *domain.CloudSnapshot]struct{}
	// metrics — counter in-memory (grand-revamp Fase 5)
	metrics *Metrics
	// logger — opsional; dipakai untuk peringatan non-fatal (mis. auto-ingest
	// melewati satu sesi). Nil = tanpa log.
	logger *slog.Logger
}

// NewSessionStore — buat SessionStore dengan pool koneksi + schema aktif.
// Schema (bukan hardcode) menentukan namespace kunci advisory lock:
// dev → "bm_dev.publish_session:...", prod → "bm.publish_session:...".
func NewSessionStore(pool *pgxpool.Pool, schema string) *SessionStore {
	return &SessionStore{
		pool:     pool,
		schema:   schema,
		watchers: make(map[string]map[chan *domain.CloudSnapshot]struct{}),
		metrics:  &Metrics{},
	}
}

// Metrics — akses counter (untuk handler GET /metrics).
func (s *SessionStore) Metrics() *Metrics { return s.metrics }

// SetLogger — set logger opsional untuk peringatan non-fatal. Aman dipanggil
// sekali saat startup; nil diperbolehkan.
func (s *SessionStore) SetLogger(l *slog.Logger) { s.logger = l }
