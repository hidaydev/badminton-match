package domain

import "testing"

func TestIsPlaceholderName(t *testing.T) {
	cases := []struct {
		name string
		want bool
	}{
		// placeholder patterns
		{"free", true},
		{"Free", true},
		{"free 1", true},
		{"free 12", true},
		{"tbd", true},
		{"TBD", true},
		{"tbd 2", true},
		{"default", true},
		{"default 3", true},
		{"xxx", true},
		{"xxx 1", true},
		{"unknown", true},
		{"kosong", true},
		{"belum ada", true},
		{"?", true},
		{"???", true},
		{"  free 1  ", true}, // whitespace dinormalisasi
		// bukan placeholder
		{"", false},
		{"   ", false},
		{"freedy", false},
		{"freebie", false},
		{"tbdoto", false},
		{"defaults", false},
		{"Xander", false},
		{"Budi", false},
		{"Azzam & Zainal", false},
		{"unknownplayer", false},
	}
	for _, c := range cases {
		if got := IsPlaceholderName(c.name); got != c.want {
			t.Errorf("IsPlaceholderName(%q) = %v, want %v", c.name, got, c.want)
		}
	}
}
