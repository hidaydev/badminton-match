// src/legacy/utils/placeholders.ts
// A placeholder slot is a seat nobody has claimed yet ("TBD", "free 1"). It is
// not a person, so the roster join keeps it out of stats and the wizard maps it
// to an empty id instead of registering a player. The server has no matching
// rule: it stores whatever id or name the client sends.
const PLACEHOLDER_RE = /^(free|tbd|default|xxx|unknown|kosong|belum ada)( \d+)?$|^\?+$/i

export function isPlaceholderName(name: string): boolean {
  const norm = name.trim().toLowerCase().replace(/\s+/g, ' ')
  if (norm === '') return false
  return PLACEHOLDER_RE.test(norm)
}
