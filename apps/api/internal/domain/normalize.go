// Package domain — tipe domain + logika bisnis murni (di-port dari SQL/frontend).
package domain

import (
	"regexp"
	"strings"
)

// whitespaceCollapse — regexp \s+ (mirror bm.normalize_player_name di SQL).
var whitespaceCollapse = regexp.MustCompile(`\s+`)

// NormalizePlayerName — port dari bm.normalize_player_name (SQL):
//
//	select nullif(regexp_replace(lower(trim(coalesce(p_name, ''))), '\s+', ' ', 'g'), '');
//
// lower + trim + collapse whitespace beruntun menjadi satu spasi.
// String kosong (atau hanya whitespace) → "". Karena Go tidak punya NULL,
// "" adalah padanan nullif(”,”) → NULL.
func NormalizePlayerName(name string) string {
	return whitespaceCollapse.ReplaceAllString(strings.ToLower(strings.TrimSpace(name)), " ")
}
