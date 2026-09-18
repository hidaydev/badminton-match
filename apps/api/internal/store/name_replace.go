package store

import (
	"strings"

	"majadu-api/internal/domain"
)

// replacePlayerNameSegment — ganti kemunculan `oldName` di dalam string
// gabungan nama (mis. pair_name "Dwi & Ismet") dengan `newName`, hanya bila
// `oldName` muncul sebagai SEGMEN UTUH (dipisah separator &, vs, ,, /, -).
//
// Tujuannya agar rename pemain tidak salah mengganti substring nama lain
// (mis. "Ari" tidak boleh mengubah "Aria"). Penggantian bersifat literal
// per-segmen; separator dan urutan asli dipertahankan.
//
// Pencocokan memakai NormalizePlayerName (lower + trim + collapse spasi) supaya
// varian alias/huruf besar-kecil/spasi ganda di pair_name tetap cocok dengan
// canonical. Separator "vs" diperlakukan sebagai kata utuh (selaras
// splitPairNames).
func replacePlayerNameSegment(combined, oldName, newName string) string {
	oldTrim := strings.TrimSpace(oldName)
	if oldTrim == "" || combined == "" {
		return combined
	}
	oldNorm := domain.NormalizePlayerName(oldTrim)
	if oldNorm == "" {
		return combined
	}
	// Pecah pada separator yang sama dengan splitPairNames, tapi simpan
	// separator agar bisa direkonstruksi.
	var b strings.Builder
	segStart := 0
	replaced := false
	var tryReplace func(string) bool
	tryReplace = func(seg string) bool {
		if replaced {
			return false
		}
		// "vs" sebagai kata utuh adalah separator (selaras splitPairNames).
		if idx := indexStandaloneVs(seg); idx >= 0 {
			left := seg[:idx]
			right := seg[idx+2:]
			if !tryReplace(left) {
				b.WriteString(left)
			}
			b.WriteString("vs")
			if !tryReplace(right) {
				b.WriteString(right)
			}
			// Segmen sudah ditulis utuh (kiri+vs+kanan); return true agar
			// pemanggil tidak menulis `seg` dua kali.
			return true
		}
		if domain.NormalizePlayerName(seg) != oldNorm {
			return false
		}
		// Pertahankan spasi tepi segmen asli; ganti isi tengahnya.
		left := strings.TrimLeft(seg, " \t")
		lead := seg[:len(seg)-len(left)]
		trail := left[len(strings.TrimRight(left, " \t")):]
		b.WriteString(lead)
		b.WriteString(newName)
		b.WriteString(trail)
		replaced = true
		return true
	}
	for i, r := range combined {
		isSep := r == '&' || r == ',' || r == '/' || r == '-'
		if !isSep {
			continue
		}
		if !tryReplace(combined[segStart:i]) {
			b.WriteString(combined[segStart:i])
		}
		b.WriteRune(r)
		segStart = i + 1
	}
	// Segmen terakhir
	if !tryReplace(combined[segStart:]) {
		b.WriteString(combined[segStart:])
	}
	if !replaced {
		return combined
	}
	return b.String()
}

// indexStandaloneVs — index awal token "vs" yang berdiri sendiri (dibatasi
// spasi/tepi), case-insensitive. -1 bila tidak ada. "Vina" tidak cocok karena
// didahului/diikuti huruf.
func indexStandaloneVs(s string) int {
	lower := strings.ToLower(s)
	for from := 0; from < len(lower); {
		idx := strings.Index(lower[from:], "vs")
		if idx < 0 {
			return -1
		}
		pos := from + idx
		leftOK := pos == 0 || !isNameChar(rune(lower[pos-1]))
		rightOK := pos+2 >= len(lower) || !isNameChar(rune(lower[pos+2]))
		if leftOK && rightOK {
			return pos
		}
		from = pos + 2
	}
	return -1
}

// isNameChar — true bila rune adalah bagian nama (bukan pembatas kata).
func isNameChar(r rune) bool {
	return (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
}
