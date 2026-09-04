package domain

import "testing"

func TestNormalizePlayerName(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want string
	}{
		{"already normalized", "fredi", "fredi"},
		{"upper case", "FREDI", "fredi"},
		{"mixed case", "Fredi", "fredi"},
		{"surrounding spaces", "  fredi  ", "fredi"},
		{"internal whitespace collapsed", "fredi   setiawan", "fredi setiawan"},
		{"tab and newline collapsed", "fredi\t\nsetiawan", "fredi setiawan"},
		{"empty", "", ""},
		{"only whitespace", "   \t  ", ""},
		{"unicode name preserved", "José", "josé"},
		{"quoted nickname", `"The Boss" Fredi`, `"the boss" fredi`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := NormalizePlayerName(tt.in); got != tt.want {
				t.Errorf("NormalizePlayerName(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}
