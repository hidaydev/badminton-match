package store

import (
	"fmt"
	"sync/atomic"
)

// Metrics — counter in-memory (ekspos via GET /metrics). Zero-dependency,
// atomic, aman untuk concurent. Bukan prometheus — cukup untuk observability
// venue skala kecil (grand-revamp Fase 5 hardening).
type Metrics struct {
	GranularOps       atomic.Int64 // total operasi granular sukses (score/played/absent)
	GranularConflicts atomic.Int64 // 409 version mismatch di granular
	Contentions       atomic.Int64 // 429 advisory/row lock contention
	AutoLocks         atomic.Int64 // auto-lock saat skor terakhir masuk
	SnapshotPuts      atomic.Int64 // PUT snapshot (deprecated path) — observability
	OutboxEvents      atomic.Int64 // event outbox tertulis
	IdempotencyHits   atomic.Int64 // dedup hit (key sama → cached)
}

// RenderMetrics — teks format Prometheus sederhana (0 dependency).
func (m *Metrics) RenderMetrics() string {
	lines := []string{
		"# majadu granular metrics (in-memory, since process start)",
		fmt.Sprintf("majadu_granular_ops_total %d", m.GranularOps.Load()),
		fmt.Sprintf("majadu_granular_conflicts_total %d", m.GranularConflicts.Load()),
		fmt.Sprintf("majadu_contentions_total %d", m.Contentions.Load()),
		fmt.Sprintf("majadu_auto_locks_total %d", m.AutoLocks.Load()),
		fmt.Sprintf("majadu_snapshot_puts_total %d", m.SnapshotPuts.Load()),
		fmt.Sprintf("majadu_outbox_events_total %d", m.OutboxEvents.Load()),
		fmt.Sprintf("majadu_idempotency_hits_total %d", m.IdempotencyHits.Load()),
	}
	out := ""
	for i, l := range lines {
		if i > 0 {
			out += "\n"
		}
		out += l
	}
	return out
}
