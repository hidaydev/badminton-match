package logfile

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// dengan tanggal tetap — injectable clock untuk uji rotasi/retensi.
func withClock(day time.Time) *Writer {
	return &Writer{now: func() time.Time { return day }, retentionDays: 7}
}

func writeAll(t *testing.T, w *Writer, s string) {
	t.Helper()
	if _, err := w.Write([]byte(s)); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func TestWriterCreatesDailyFile(t *testing.T) {
	dir := t.TempDir()
	w := withClock(time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC))
	w.dir = dir
	if err := w.rotate(); err != nil {
		t.Fatalf("rotate: %v", err)
	}
	writeAll(t, w, "line one\n")

	content, err := os.ReadFile(filepath.Join(dir, "app-2026-08-15.log"))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !strings.Contains(string(content), "line one") {
		t.Fatalf("isi file tidak cocok: %q", content)
	}
}

func TestWriterRotatesOnDateChange(t *testing.T) {
	dir := t.TempDir()
	day := time.Date(2026, 8, 15, 23, 59, 59, 0, time.UTC)
	w := withClock(day)
	w.dir = dir
	if err := w.rotate(); err != nil {
		t.Fatalf("rotate: %v", err)
	}
	writeAll(t, w, "day 15\n")

	// pindah ke hari berikutnya
	w.now = func() time.Time { return day.Add(2 * time.Second) }
	writeAll(t, w, "day 16\n")

	d15, _ := os.ReadFile(filepath.Join(dir, "app-2026-08-15.log"))
	d16, _ := os.ReadFile(filepath.Join(dir, "app-2026-08-16.log"))
	if !strings.Contains(string(d15), "day 15") {
		t.Fatalf("file 15 salah: %q", d15)
	}
	if !strings.Contains(string(d16), "day 16") {
		t.Fatalf("file 16 salah: %q", d16)
	}
	if strings.Contains(string(d15), "day 16") {
		t.Fatalf("day 16 nyasar ke file 15: %q", d15)
	}
}

func TestWriterPrunesExpired(t *testing.T) {
	dir := t.TempDir()
	// file lama (9 hari lalu) + file baru (hari ini)
	old := filepath.Join(dir, "app-2026-08-06.log")
	_ = os.WriteFile(old, []byte("old"), 0o644)
	cur := filepath.Join(dir, "app-2026-08-15.log")
	_ = os.WriteFile(cur, []byte("cur"), 0o644)

	w := withClock(time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC))
	w.dir = dir
	if err := w.rotate(); err != nil {
		t.Fatalf("rotate: %v", err)
	}

	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatalf("file lama harus dihapus (retensi 7 hari)")
	}
	if _, err := os.Stat(cur); err != nil {
		t.Fatalf("file hari ini harus tetap ada: %v", err)
	}
}

func TestWriterKeepsFilesWithinRetention(t *testing.T) {
	dir := t.TempDir()
	// 5 hari lalu (masih dalam 7 hari) harus tetap ada
	keep := filepath.Join(dir, "app-2026-08-10.log")
	_ = os.WriteFile(keep, []byte("keep"), 0o644)

	w := withClock(time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC))
	w.dir = dir
	if err := w.rotate(); err != nil {
		t.Fatalf("rotate: %v", err)
	}
	if _, err := os.Stat(keep); err != nil {
		t.Fatalf("file 5 hari lalu harus tetap ada: %v", err)
	}
}
