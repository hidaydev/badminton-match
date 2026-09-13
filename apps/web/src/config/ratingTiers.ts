// src/config/ratingTiers.ts — tier rating 8-band (TIER_8_UNIFICATION.md §3.2).
// Bands: D ≤1199 · D+ 1200-1299 · C 1300-1499 · C+ 1500-1599
//        B 1600-1799 · B+ 1800-1899 · A 1900-2099 · A+ ≥2100
// Palet graphite+gold (tanpa indigo/violet — aturan redesign).

export type RatingTier = 'D' | 'D+' | 'C' | 'C+' | 'B' | 'B+' | 'A' | 'A+'

export const RATING_TIER_BADGE_COLORS: Record<RatingTier, string> = {
  'D': 'bg-slate-600/40 text-slate-300 border-slate-500',
  'D+': 'bg-stone-700/40 text-stone-300 border-stone-500',
  'C': 'bg-amber-800/40 text-amber-500 border-amber-700',
  'C+': 'bg-amber-700/40 text-amber-400 border-amber-600',
  'B': 'bg-yellow-700/40 text-yellow-300 border-yellow-600',
  'B+': 'bg-yellow-600/40 text-yellow-200 border-yellow-500',
  'A': 'bg-accent/20 text-accent border-accent/50',
  'A+': 'bg-accent/30 text-accent border-accent',
}
