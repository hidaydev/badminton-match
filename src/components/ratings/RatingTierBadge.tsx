// src/components/ratings/RatingTierBadge.tsx — badge tier rating D..S+.
import { RATING_TIER_BADGE_COLORS, type RatingClass } from '../../config/ratingTiers'

// Badge kelas rating 12 sub-tier (D-..A+). class_display = max(derived, floor).
export default function RatingTierBadge({ class: cls, size = 'sm' }: { class: string; size?: 'sm' | 'md' }) {
  const color = RATING_TIER_BADGE_COLORS[cls as RatingClass] ?? RATING_TIER_BADGE_COLORS['D-']
  const pad = size === 'md' ? 'px-2 py-0.5 text-xs' : 'px-1.5 py-0.5 text-[10px]'
  return (
    <span
      className={`inline-flex items-center justify-center min-w-6 rounded border font-bold ${pad} ${color}`}
      title={`Kelas ${cls}`}
    >
      {cls}
    </span>
  )
}
