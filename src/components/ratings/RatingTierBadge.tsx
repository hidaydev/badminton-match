// src/components/ratings/RatingTierBadge.tsx — badge tier rating D..S+.
import { RATING_TIER_LABELS, RATING_TIER_BADGE_COLORS } from '../../config/ratingTiers'

export default function RatingTierBadge({ tier, size = 'sm' }: { tier: number; size?: 'sm' | 'md' }) {
  const cls = RATING_TIER_BADGE_COLORS[tier] ?? RATING_TIER_BADGE_COLORS[1]
  const pad = size === 'md' ? 'px-2 py-0.5 text-xs' : 'px-1.5 py-0.5 text-[10px]'
  return (
    <span
      className={`inline-flex items-center justify-center min-w-6 rounded border font-bold ${pad} ${cls}`}
      title={`Tier ${RATING_TIER_LABELS[tier] ?? tier}`}
    >
      {RATING_TIER_LABELS[tier] ?? tier}
    </span>
  )
}
