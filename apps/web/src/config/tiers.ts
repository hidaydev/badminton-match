// 8-tier (TIER_8_UNIFICATION.md): 1=D, 2=D+, 3=C, 4=C+, 5=B, 6=B+, 7=A, 8=A+
export const TIER_LABELS: Record<number, string> = {
  1: 'D', 2: 'D+', 3: 'C', 4: 'C+', 5: 'B', 6: 'B+', 7: 'A', 8: 'A+',
}

export const TIER_COLORS: Record<number, string> = {
  1: 'text-green-400',
  2: 'text-green-300',
  3: 'text-yellow-400',
  4: 'text-yellow-300',
  5: 'text-orange-400',
  6: 'text-orange-300',
  7: 'text-red-400',
  8: 'text-red-300',
}

export const TIER_BADGE_COLORS: Record<number, string> = {
  1: 'bg-green-500/20 text-green-400 border-green-600',
  2: 'bg-green-500/20 text-green-300 border-green-500',
  3: 'bg-yellow-500/20 text-yellow-400 border-yellow-600',
  4: 'bg-yellow-500/20 text-yellow-300 border-yellow-500',
  5: 'bg-orange-500/20 text-orange-400 border-orange-600',
  6: 'bg-orange-500/20 text-orange-300 border-orange-500',
  7: 'bg-red-500/20 text-red-400 border-red-600',
  8: 'bg-red-500/20 text-red-300 border-red-500',
}

export const TIER_ACTIVE: Record<number, string> = {
  1: 'bg-green-500 text-white',
  2: 'bg-green-400 text-slate-900',
  3: 'bg-yellow-500 text-slate-900',
  4: 'bg-yellow-400 text-slate-900',
  5: 'bg-orange-500 text-white',
  6: 'bg-orange-400 text-slate-900',
  7: 'bg-red-500 text-white',
  8: 'bg-red-400 text-slate-900',
}

export const TIER_NAMES: Record<number, string> = {
  1: 'Beginner',
  2: 'Novice',
  3: 'Recreational',
  4: 'Improving',
  5: 'Intermediate',
  6: 'Advanced',
  7: 'Expert',
  8: 'Elite',
}
