// src/utils/placeholders.ts
// Pola nama placeholder — MIRROR majadu-api/internal/domain/placeholder.go
// (IsPlaceholderName). Jaga konsisten (ABSENT_TBD_PLAYERS_DESIGN.md §5.2).
const PLACEHOLDER_RE = /^(free|tbd|default|xxx|unknown|kosong|belum ada)( \d+)?$|^\?+$/i

export function isPlaceholderName(name: string): boolean {
  const norm = name.trim().toLowerCase().replace(/\s+/g, ' ')
  if (norm === '') return false
  return PLACEHOLDER_RE.test(norm)
}
