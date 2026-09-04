package domain

import "regexp"

// placeholderNameRe — pola nama placeholder (ABSENT_TBD_PLAYERS_DESIGN.md §5.2).
// Pemain placeholder TIDAK diregistrasi ke players/aliases; player_id di
// session_players = NULL; game yang memuatnya = VOID.
//
// Case-insensitive via NormalizePlayerName (lower + trim + collapse spasi).
// Menyertakan angka opsi: "free 1", "tbd 2", dst.
var placeholderNameRe = regexp.MustCompile(`^(free|tbd|default|xxx|unknown|kosong|belum ada)( \d+)?$|^\?+$`)

// IsPlaceholderName — true jika nama pemain cocok pola placeholder.
// Nama blank/whitespace = false (tetap ditolak validasi sebagai "blank name",
// bukan placeholder).
func IsPlaceholderName(name string) bool {
	norm := NormalizePlayerName(name)
	if norm == "" {
		return false
	}
	return placeholderNameRe.MatchString(norm)
}
