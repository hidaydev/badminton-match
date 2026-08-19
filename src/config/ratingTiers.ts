// src/config/ratingTiers.ts — tier rating D..S+ (1-10) per RATING_ENGINE_DESIGN.md §7.
// Palet graphite+gold (tanpa indigo/violet — aturan redesign). Bands:
//   10 S+ ≥1800 · 9 S 1700 · 8 A+ 1600 · 7 A 1500 · 6 B+ 1400 · 5 B 1300
//   4 C+ 1200 · 3 C 1100 · 2 D+ 1050 · 1 D <1050

export const RATING_TIER_LABELS: Record<number, string> = {
  1: 'D', 2: 'D+', 3: 'C', 4: 'C+', 5: 'B', 6: 'B+', 7: 'A', 8: 'A+', 9: 'S', 10: 'S+',
}

export const RATING_TIER_BADGE_COLORS: Record<number, string> = {
  1: 'bg-slate-700/40 text-slate-400 border-slate-600',
  2: 'bg-slate-600/40 text-slate-300 border-slate-500',
  3: 'bg-stone-700/40 text-stone-300 border-stone-500',
  4: 'bg-amber-900/40 text-amber-500 border-amber-800',
  5: 'bg-amber-800/40 text-amber-400 border-amber-700',
  6: 'bg-amber-700/40 text-amber-300 border-amber-600',
  7: 'bg-amber-600/40 text-amber-200 border-amber-500',
  8: 'bg-yellow-700/40 text-yellow-300 border-yellow-600',
  9: 'bg-yellow-600/40 text-yellow-200 border-yellow-500',
  10: 'bg-accent/15 text-accent border-accent/40',
}
