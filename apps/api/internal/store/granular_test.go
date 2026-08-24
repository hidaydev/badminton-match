package store

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
)

// ── Unit test granular (pure, tanpa DB) ─────────────────────────────────────

func TestSplitGameKey(t *testing.T) {
	tests := []struct {
		key      string
		wantSlot int
		wantCourt int
		wantOK   bool
	}{
		{"0-0", 0, 0, true},
		{"12-3", 12, 3, true},
		{"0-1", 0, 1, true},
		{"", 0, 0, false},
		{"0", 0, 0, false},
		{"-1-0", 0, 0, false},
		{"a-b", 0, 0, false},
		{"0--1", 0, 0, false},
		{" 0-0", 0, 0, false}, // trim tidak dilakukan — key harus rapi dari client
	}
	for _, tt := range tests {
		slot, court, ok := splitGameKey(tt.key)
		if ok != tt.wantOK {
			t.Errorf("splitGameKey(%q) ok = %v, want %v", tt.key, ok, tt.wantOK)
			continue
		}
		if ok && (slot != tt.wantSlot || court != tt.wantCourt) {
			t.Errorf("splitGameKey(%q) = (%d,%d), want (%d,%d)", tt.key, slot, court, tt.wantSlot, tt.wantCourt)
		}
	}
}

func TestIsUndefinedTable(t *testing.T) {
	if isUndefinedTable(nil) {
		t.Fatal("nil should be false")
	}
	var pgErr *pgconn.PgError
	pgErr = &pgconn.PgError{Code: "42P01", Message: `relation "idempotency_keys" does not exist`}
	if !isUndefinedTable(pgErr) {
		t.Fatal("42P01 should be true")
	}
	pgErr = &pgconn.PgError{Code: "42P07", Message: `relation "outbox_events" already exists`}
	if !isUndefinedTable(pgErr) {
		t.Fatal("42P07 should be true")
	}
	pgErr = &pgconn.PgError{Code: "23505", Message: "duplicate key"}
	if isUndefinedTable(pgErr) {
		t.Fatal("23505 should be false")
	}
	if isUndefinedTable(errors.New("generic error")) {
		t.Fatal("generic error should be false")
	}
	if !isUndefinedTable(errors.New("wrapped: relation does not exist")) {
		t.Fatal("string fallback 'does not exist' should be true")
	}
	if !isUndefinedTable(errors.New("wrapped: 42P01")) {
		t.Fatal("string fallback '42P01' should be true")
	}
}

func TestSplitGameKeyNegativeFails(t *testing.T) {
	// splitGameKey harus menolak slot/court negatif (validate snapshot pakai non-negative)
	for _, key := range []string{"-1-0", "0--1", "-2-3"} {
		if _, _, ok := splitGameKey(key); ok {
			t.Errorf("expected %q rejected", key)
		}
	}
}

func TestGameRowJSONShape(t *testing.T) {
	// Pastikan field JSON yang diekspos konsisten (FE getGame pakai ini)
	g := GameRow{Slot: 0, Court: 0, ScoreA: intPtr(21), ScoreB: intPtr(15), IsPlayed: true, Version: 4}
	raw := marshalJSON(t, g)
	for _, want := range []string{`"slot":0`, `"court":0`, `"scoreA":21`, `"scoreB":15`, `"isPlayed":true`, `"version":4`} {
		if !strings.Contains(raw, want) {
			t.Errorf("GameRow JSON missing %s in %s", want, raw)
		}
	}
}

func intPtr(v int) *int { return &v }

func marshalJSON(t *testing.T, v any) string {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return string(raw)
}
