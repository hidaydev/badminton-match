// Realtime pub/sub untuk SSE watch (Subscribe/Unsubscribe/Broadcast).

package store

import (
	"majadu-api/internal/domain"
)

// Subscribe — daftar untuk SSE watch pada session id. Kembalikan channel dan cancel func.
func (s *SessionStore) Subscribe(id string) (chan *domain.CloudSnapshot, func()) {
	ch := make(chan *domain.CloudSnapshot, 4)
	s.mu.Lock()
	if s.watchers[id] == nil {
		s.watchers[id] = make(map[chan *domain.CloudSnapshot]struct{})
	}
	s.watchers[id][ch] = struct{}{}
	s.mu.Unlock()
	cancel := func() { s.Unsubscribe(id, ch) }
	return ch, cancel
}

// Unsubscribe — hapus subscriber dan tutup channel.
func (s *SessionStore) Unsubscribe(id string, ch chan *domain.CloudSnapshot) {
	s.mu.Lock()
	if m, ok := s.watchers[id]; ok {
		delete(m, ch)
		if len(m) == 0 {
			delete(s.watchers, id)
		}
	}
	s.mu.Unlock()
	// Close di luar lock biar tidak deadlock jika ada Broadcast yang hold RLock
	// dan coba kirim ke chan yang baru dihapus (select default sudah non-blocking).
	// Close hanya sekali — Unsubscribe dipanggil sekali per Subscribe via defer.
	func() {
		defer func() { _ = recover() }() // jika sudah close
		close(ch)
	}()
}

// Broadcast — kirim snapshot baru ke semua subscriber session id. Non-blocking (slow client drop).
func (s *SessionStore) Broadcast(id string, snap *domain.CloudSnapshot) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	m, ok := s.watchers[id]
	if !ok {
		return
	}
	for ch := range m {
		select {
		case ch <- snap:
		default:
			// buffer penuh → drop (client akan dapat snapshot terbaru di next broadcast)
		}
	}
}
