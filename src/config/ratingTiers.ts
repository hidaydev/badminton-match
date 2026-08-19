// src/config/ratingTiers.ts — tier rating D..S+ (1-10) per RATING_ENGINE_DESIGN.md §7.
// Palet graphite+gold (tanpa indigo/violet — aturan redesign). Bands:
//   10 S+ ≥1800 · 9 S 1700 · 8 A+ 1600 · 7 A 1500 · 6 B+ 1400 · 5 B 1300
//   4 C+ 1200 · 3 C 1100 · 2 D+ 1050 · 1 D <1050

export type RatingClass = 'D-' | 'D' | 'D+' | 'C-' | 'C' | 'C+' | 'B-' | 'B' | 'B+' | 'A-' | 'A' | 'A+'

export const RATING_TIER_BADGE_COLORS: Record<RatingClass, string> = {
  'D-': 'bg-slate-700/40 text-slate-400 border-slate-600',
  'D': 'bg-slate-600/40 text-slate-300 border-slate-500',
  'D+': 'bg-stone-700/40 text-stone-300 border-stone-500',
  'C-': 'bg-amber-900/40 text-amber-600 border-amber-800',
  'C': 'bg-amber-800/40 text-amber-500 border-amber-700',
  'C+': 'bg-amber-700/40 text-amber-400 border-amber-600',
  'B-': 'bg-amber-600/40 text-amber-300 border-amber-500',
  'B': 'bg-yellow-700/40 text-yellow-300 border-yellow-600',
  'B+': 'bg-yellow-600/40 text-yellow-200 border-yellow-500',
  'A-': 'bg-yellow-500/40 text-yellow-200 border-yellow-500',
  'A': 'bg-accent/20 text-accent border-accent/50',
  'A+': 'bg-accent/30 text-accent border-accent',
}
