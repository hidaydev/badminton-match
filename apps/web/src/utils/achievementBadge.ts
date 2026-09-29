// src/utils/achievementBadge.ts, pemetaan data medal ke visual badge.
import { EVENT_TONES, MEDAL_TONES } from '../config/achievements'

// MedalIcon — nama glyph. Tiap medal punya ikon sendiri supaya tidak ada yang
// kembar; badge memang tanpa teks, jadi ikon + warna adalah satu-satunya penanda.
export type MedalIcon =
  | 'check'
  | 'shuttlecock'
  | 'trophy'
  | 'flame'
  | 'team'
  | 'versus'
  | 'flag'

// medalIcon — achievement_key → ikon.
export function medalIcon(key: string): MedalIcon {
  switch (key) {
    case 'medal:sessions':
      return 'check'
    case 'medal:games':
      return 'shuttlecock'
    case 'medal:wins':
      return 'trophy'
    case 'medal:streak':
      return 'flame'
    case 'medal:partners':
      return 'team'
    case 'medal:opponents':
      return 'versus'
  }
  if (key.startsWith('tournament:')) return 'flag'
  return 'trophy'
}

// isEventKey — badge event (satu per event) vs milestone bertingkat.
// Badge season sudah dihapus bersama pensiunnya konsep season (2026-09-29).
export function isEventKey(key: string): boolean {
  return key.startsWith('tournament:')
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

// eventTone — warna unik deterministik untuk medal event (turnamen).
export function eventTone(seed: string): string {
  return EVENT_TONES[hashSeed(seed) % EVENT_TONES.length]
}

// seedFromKey — ambil id event dari achievement_key, kalau badge event.
export function seedFromKey(key: string): string | undefined {
  const prefix = 'tournament:'
  if (key.startsWith(prefix)) return key.slice(prefix.length)
  return undefined
}
