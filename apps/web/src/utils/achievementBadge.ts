// src/utils/achievementBadge.ts, pemetaan data medal ke visual badge.
import { EVENT_TONES, MEDAL_TONES } from '../config/achievements'

// MedalIcon — nama glyph. Tiap medal punya ikon sendiri supaya tidak ada yang
// kembar; badge memang tanpa teks, jadi ikon + warna adalah satu-satunya penanda.
export type MedalIcon =
  | 'check'
  | 'shuttlecock'
  | 'trophy'
  | 'arrow-up'
  | 'flame'
  | 'team'
  | 'versus'
  | 'flag'
  | 'calendar'

// medalIcon — achievement_key → ikon.
export function medalIcon(key: string): MedalIcon {
  switch (key) {
    case 'medal:sessions':
      return 'check'
    case 'medal:games':
      return 'shuttlecock'
    case 'medal:wins':
      return 'trophy'
    case 'medal:rating':
      return 'arrow-up'
    case 'medal:streak':
      return 'flame'
    case 'medal:partners':
      return 'team'
    case 'medal:opponents':
      return 'versus'
  }
  if (key.startsWith('tournament:')) return 'flag'
  if (key.startsWith('season_member:')) return 'calendar'
  return 'trophy'
}

// isEventKey — badge event (satu per event) vs milestone bertingkat.
export function isEventKey(key: string): boolean {
  return key.startsWith('tournament:') || key.startsWith('season_member:')
}

// medalTone — warna pangkat untuk level 1..5 (Bronze..Onyx).
export function medalTone(level: number | undefined): string | undefined {
  if (!level || level < 1 || level > MEDAL_TONES.length) return undefined
  return MEDAL_TONES[level - 1]
}

// hashSeed — hash deterministik sederhana (FNV-1a) dari id.
export function hashSeed(s: string): number {
  let h = 2166136261
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i)
    h = Math.imul(h, 16777619)
  }
  return Math.abs(h)
}

// eventTone — warna unik deterministik untuk medal event (turnamen/season).
export function eventTone(seed: string): string {
  return EVENT_TONES[hashSeed(seed) % EVENT_TONES.length]
}

// seedFromKey — ambil id event/season dari achievement_key, kalau badge event.
export function seedFromKey(key: string): string | undefined {
  for (const prefix of ['tournament:', 'season_member:']) {
    if (key.startsWith(prefix)) return key.slice(prefix.length)
  }
  return undefined
}

// monogram — sampai 3 huruf dari nama event, dipakai sebagai emblem unik.
export function monogram(name: string | undefined): string | undefined {
  if (!name) return undefined
  const skip = new Set(['majadu', 'the', 'of', 'and', 'a', 'an', 'internal', 'tournament', 'cup', 'open', 'season'])
  const tokens = name.split(/\s+/).filter((w) => /[A-Za-z0-9]/.test(w))
  const significant = tokens.filter((w) => !skip.has(w.toLowerCase()))
  const source = significant.length > 0 ? significant : tokens
  if (source.length === 0) return undefined
  const letters = source.length === 1 ? source[0].replace(/[^A-Za-z0-9]/g, '').slice(0, 3) : source.slice(0, 3).map((w) => w.replace(/[^A-Za-z0-9]/g, '')[0] ?? '').join('')
  return letters.toUpperCase() || undefined
}
