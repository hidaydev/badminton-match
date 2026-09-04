// Package logfile — writer log harian ala catalina.out: satu file per hari
// (app-YYYY-MM-DD.log), rotasi otomatis saat ganti hari, dan retensi file
// historis N hari (file lebih tua dari retensi dihapus saat rotasi/startup).
package logfile

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

// Writer — io.Writer thread-safe yang menulis ke file per-hari di `dir`.
// Cocok dipakai sebagai target slog handler.
type Writer struct {
	mu            sync.Mutex
	dir           string
	retentionDays int
	now           func() time.Time // injectable untuk test
	currentDate   string
	file          *os.File
}

// New — buat Writer; direktori dibuat kalau belum ada.
// retentionDays <= 0 → tanpa pembersihan file lama.
func New(dir string, retentionDays int) (*Writer, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("logfile: create dir: %w", err)
	}
	w := &Writer{dir: dir, retentionDays: retentionDays, now: time.Now}
	if err := w.rotate(); err != nil {
		return nil, err
	}
	return w, nil
}

// Write — tulis ke file hari ini; rotasi dulu kalau ganti hari.
func (w *Writer) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if date := w.now().Format("2006-01-02"); date != w.currentDate {
		if err := w.rotate(); err != nil {
			return 0, err
		}
	}
	return w.file.Write(p)
}

// Close — tutup file aktif.
func (w *Writer) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.file != nil {
		return w.file.Close()
	}
	return nil
}

// rotate — buka file hari ini (tutup yang lama) + prune file expired.
func (w *Writer) rotate() error {
	if w.file != nil {
		_ = w.file.Close()
	}
	now := w.now()
	w.currentDate = now.Format("2006-01-02")
	f, err := os.OpenFile(
		filepath.Join(w.dir, fmt.Sprintf("app-%s.log", w.currentDate)),
		os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	w.file = f
	return w.prune(now)
}

// prune — hapus app-*.log dengan tanggal < hari ini - retentionDays.
func (w *Writer) prune(now time.Time) error {
	if w.retentionDays <= 0 {
		return nil
	}
	entries, err := os.ReadDir(w.dir)
	if err != nil {
		return err
	}
	cutoff := now.AddDate(0, 0, -w.retentionDays)
	expired := []string{}
	for _, e := range entries {
		if e.IsDir() || !strings.HasPrefix(e.Name(), "app-") || !strings.HasSuffix(e.Name(), ".log") {
			continue
		}
		day := strings.TrimSuffix(strings.TrimPrefix(e.Name(), "app-"), ".log")
		d, err := time.Parse("2006-01-02", day)
		if err != nil {
			continue // nama tak dikenal — biarkan
		}
		if d.Before(cutoff) {
			expired = append(expired, e.Name())
		}
	}
	sort.Strings(expired)
	for _, name := range expired {
		_ = os.Remove(filepath.Join(w.dir, name))
	}
	return nil
}
