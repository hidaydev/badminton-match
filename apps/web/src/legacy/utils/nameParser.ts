// src/utils/nameParser.ts — Parser nama pemain dengan anotasi penjelas dalam kurung (...).

export interface ParsedPlayerName {
  baseName: string
  annotation: string | null
}

/**
 * Memecah nama pemain menjadi nama utama (baseName) dan anotasi penjelas (annotation)
 * jika terdapat teks dalam kurung.
 *
 * Contoh:
 *   - "Arya (Shania)"       -> { baseName: "Arya", annotation: "Shania" }
 *   - "Arya (Dika)"         -> { baseName: "Arya", annotation: "Dika" }
 *   - "Andra (temen novian)"-> { baseName: "Andra", annotation: "temen novian" }
 *   - "Bowo"                -> { baseName: "Bowo", annotation: null }
 */
export function parsePlayerName(fullName: string | null | undefined): ParsedPlayerName {
  if (!fullName) return { baseName: '', annotation: null }
  const trimmed = fullName.trim()
  const match = trimmed.match(/^(.*?)\s*\((.*?)\)$/)
  if (match && match[1].trim()) {
    return {
      baseName: match[1].trim(),
      annotation: match[2].trim(),
    }
  }
  return { baseName: trimmed, annotation: null }
}

/**
 * Kumpulkan baseName yang DUPLIKAT (dipakai oleh lebih dari satu nama tampilan).
 * Anotasi/`(i)` hanya berguna untuk nama yang ambigu — kalau baseName cuma
 * muncul sekali, anotasi hanya noise (mis. "Miqdad (Teman Ismet)" padahal
 * satu-satunya Miqdad). Bandingkan case-insensitive.
 */
export function collectAmbiguousBaseNames(names: Iterable<string>): Set<string> {
  const counts = new Map<string, number>()
  for (const n of names) {
    const base = parsePlayerName(n).baseName.toLowerCase()
    if (!base) continue
    counts.set(base, (counts.get(base) ?? 0) + 1)
  }
  const out = new Set<string>()
  for (const [base, count] of counts) {
    if (count > 1) out.add(base)
  }
  return out
}

// combineAmbiguous — gabungkan set ambigu global (populasi) dengan set konteks
// lokal. Halaman TIDAK boleh mengganti set global: nama yang ambigu di seluruh
// populasi tetap ambigu walau di halaman ini hanya muncul sekali (mis. riwayat
// satu pemain memuat lawan "Arya (Dika)" sementara "Arya (Shania)" tidak
// tampil). Union = benar untuk keduanya.
export function combineAmbiguous(
  global: ReadonlySet<string>,
  ...locals: ReadonlySet<string>[]
): ReadonlySet<string> {
  const out = new Set(global)
  for (const l of locals) for (const v of l) out.add(v)
  return out
}
