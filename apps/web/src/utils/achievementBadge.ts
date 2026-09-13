// src/utils/achievementBadge.ts, pemetaan data medal ke visual badge.
import type { AchievementKind } from '../components/ratings/AchievementBadge'
import { EVENT_TONES, MEDAL_TONES } from '../config/achievements'

// badgeKind — kind dari API → glyph badge.
export function badgeKind(kind: string): AchievementKind {
  switch (kind) {
    case 'tournament':
      return 'tournament'
    case 'season':
      return 'season'
    case 'attendance':
      return 'attendance'
    case 'social':
      return 'social'
    case 'opponent':
      return 'opponent'
    default:
      // volume, rating
      return 'volume'
  }
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

// monogram — 2 huruf dari nama event, dipakai sebagai emblem unik.
export function monogram(name: string | undefined): string | undefined {
  if (!name) return undefined
  const skip = new Set(['majadu', 'the', 'of', 'and', 'a', 'an', 'internal', 'tournament', 'cup', 'open'])
  const words = name.split(/\s+/).filter((w) => /[A-Za-z0-9]/.test(w))
  const significant = words.filter((w) => !skip.has(w.toLowerCase()))
  const source = (significant.length > 0 ? significant : words).slice(0, 2)
  const letters = source.map((w) => w[0]?.toUpperCase() ?? '').join('')
  return letters || undefined
}
