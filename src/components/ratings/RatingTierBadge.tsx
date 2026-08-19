// src/components/ratings/RatingTierBadge.tsx — badge tier rating 8-band.
import { RATING_TIER_BADGE_COLORS, type RatingTier } from '../../config/ratingTiers'

// Badge tier 8 (TIER_8_UNIFICATION). `tier` = tier_display (max derived vs floor).
export default function RatingTierBadge({ tier, size = 'sm' }: { tier: string; size?: 'sm' | 'md' }) {
  const color = RATING_TIER_BADGE_COLORS[tier as RatingTier] ?? RATING_TIER_BADGE_COLORS['D']
  const pad = size === 'md' ? 'px-2 py-0.5 text-xs' : 'px-1.5 py-0.5 text-[10px]'
  return (
    <span
      className={`inline-flex items-center justify-center min-w-6 rounded border font-bold ${pad} ${color}`}
      title={`Tier ${tier}`}
    >
      {tier}
    </span>
  )
}
