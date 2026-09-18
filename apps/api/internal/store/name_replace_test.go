package store

import "testing"

func TestReplacePlayerNameSegment(t *testing.T) {
	cases := []struct {
		name     string
		combined string
		oldName  string
		newName  string
		want     string
	}{
		{"ganti segmen pertama", "Dwi & Ismet", "Dwi", "Dwi Kurniawan", "Dwi Kurniawan & Ismet"},
		{"ganti segmen kedua", "Dwi & Ismet", "Ismet", "Ismet A", "Dwi & Ismet A"},
		{"nama tidak ada", "Dwi & Ismet", "Bowo", "Bowo X", "Dwi & Ismet"},
		{"substring nama lain tidak ikut berubah", "Aria & Bowo", "Ari", "Ariyanto", "Aria & Bowo"},
		{"segmen utuh cocok", "Ari & Bowo", "Ari", "Ariyanto", "Ariyanto & Bowo"},
		{"separator koma", "Dwi, Ismet", "Ismet", "Ismet B", "Dwi, Ismet B"},
		{"anotasi sebagai segmen utuh", "Miqdad (Teman Ismet) & Bowo", "Miqdad (Teman Ismet)", "Miqdad", "Miqdad & Bowo"},
		{"hanya ganti satu kemunculan", "Dwi & Dwi", "Dwi", "Dwi A", "Dwi A & Dwi"},
		{"separator vs kata utuh", "Dwi vs Ismet", "Ismet", "Ismet A", "Dwi vs Ismet A"},
		{"vs di dalam nama tidak jadi separator", "Vina vs Bowo", "Vina", "Vina B", "Vina B vs Bowo"},
		{"cocok walau beda kapital", "dwi & Ismet", "Dwi", "Dwi K", "Dwi K & Ismet"},
		{"cocok walau spasi ganda", "Dwi   & Ismet", "Dwi", "Dwi K", "Dwi K   & Ismet"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := replacePlayerNameSegment(c.combined, c.oldName, c.newName); got != c.want {
				t.Fatalf("replacePlayerNameSegment(%q, %q, %q) = %q, want %q",
					c.combined, c.oldName, c.newName, got, c.want)
			}
		})
	}
}
