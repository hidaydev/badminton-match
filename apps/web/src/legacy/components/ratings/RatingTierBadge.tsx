// src/components/ratings/RatingTierBadge.tsx — badge tier 8-band (sticky).
import { RATING_TIER_BADGE_COLORS, type RatingTier } from '../../config/ratingTiers'

// 8-tier badge (TIER_8_UNIFICATION). `tier` is players.tier (sticky, admin).
// Glicko was retired, so there is no derived rating tier any more.
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
