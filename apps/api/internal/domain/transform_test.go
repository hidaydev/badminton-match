package domain

import (
	"errors"
	"testing"
)

// Boundary cases skor — MIRROR scripts/tests/scoreValidation.test.ts di frontend.
// Dua sisi harus selalu konsisten (parity rule).
func TestValidateScore(t *testing.T) {
	cases := []struct {
		name string
		a, b int
		want error
	}{
		{"21-18 valid", 21, 18, nil},
		{"0-0 sama", 0, 0, errScoresEqual},
		{"21-21 sama", 21, 21, errScoresEqual},
		{"negatif", -1, 5, errScoresNegative},
		{"keduanya negatif", -2, -3, errScoresNegative},
		{"melebihi 99", 100, 15, errScoresTooHigh},
		{"99 batas atas valid", 99, 98, nil},
		{"0 batas bawah valid", 0, 5, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := ValidateScore(c.a, c.b)
			if !errors.Is(got, c.want) {
				t.Fatalf("ValidateScore(%d,%d) = %v, want %v", c.a, c.b, got, c.want)
			}
		})
	}
}
