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
