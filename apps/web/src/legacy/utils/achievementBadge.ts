// src/utils/achievementBadge.ts, pemetaan data medal ke visual badge.
import { EVENT_TONES, MEDAL_TONES } from '../config/achievements'

// MedalIcon: the glyph name. Every medal has its own icon so none repeat; the
// badge carries no text, so the icon plus the colour are the only markers.
export type MedalIcon =
  | 'check'
  | 'shuttlecock'
  | 'trophy'
  | 'flame'
  | 'team'
  | 'versus'
  | 'flag'
  | 'podium'
  | 'stairup'

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
    case 'medal:rank':
      return 'podium'
    case 'medal:rank_streak':
      return 'stairup'
  }
  if (key.startsWith('tournament:')) return 'flag'
  return 'trophy'
}

// isEventKey — badge event (satu per event) vs milestone bertingkat.
// Season badges were removed together with the retirement of the season
// concept (2026-09-29).
export function isEventKey(key: string): boolean {
  return key.startsWith('tournament:')
}

// medalTone: the rank colour for levels 1..5 (Bronze..Onyx).
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

// eventTone: the deterministic unique colour for an event medal (tournament).
export function eventTone(seed: string): string {
  return EVENT_TONES[hashSeed(seed) % EVENT_TONES.length]
}

// seedFromKey: take the event id out of an achievement_key when the badge is an
// event medal.
export function seedFromKey(key: string): string | undefined {
  const prefix = 'tournament:'
  if (key.startsWith(prefix)) return key.slice(prefix.length)
  return undefined
}
