// src/components/ratings/AchievementBadge.tsx, badge koleksi achievement
// berbentuk shield/patch. Presentasional murni: seluruh isi datang dari props,
// tidak ada data contoh di dalam komponen.
//
// Alasan tiap keputusan (R-31):
// - Shield/patch: menandai "pencapaian terkumpul", beda dari chip tier yang
//   sudah ada (RatingTierBadge). Bentuknya badge, bukan label status.
// - Yang tampil hanya NAMA achievement; deskripsi pindah ke popup (permintaan
//   user) supaya rak tetap rapi. `showDetail` hanya untuk halaman pratinjau.
// - Tiga mode visual, dipilih dari props:
//     1. medal (tierLevel 1..5): warna pangkat Bronze..Onyx + 5 pips tingkat.
//     2. event unik (seed): siluet dipilih deterministik dari id + tone dari
//        palet event, emblem monogram nama event. Tiap event jadi khas.
//     3. skill tier (tier): 8 pips + ramp tepi seperti sebelumnya.
// - Warna dari token app; satu accent, tanpa gradient/glow/shadow (R-01, R-13).
// - Glyph relevan ke makna (R-04): shuttlecock = ikut turnamen, chevron naik =
//   breakthrough tier, dst. Bukan ikon generik.
// - Kalau `onSelect` diberi, root jadi button (keyboard: Tab + Enter/Space,
//   focus ring global). Tanpa `onSelect` root cuma div (non-interaktif).
// - State terkunci dibedakan lewat garis putus + opacity, bukan warna baru
//   (R-29). Tanpa animasi (MOTION 1).

import { ACHIEVEMENT_TIER_EDGE, TIER_RANK, type RatingTier } from '../../config/ratingTiers'
import { eventShape, eventTone, medalTone } from '../../utils/achievementBadge'

export type AchievementKind =
  | 'tournament'
  | 'tier'
  | 'attendance'
  | 'volume'
  | 'social'
  | 'opponent'
  | 'season'

export type AchievementState = 'earned' | 'locked'

export interface AchievementBadgeProps {
  kind: AchievementKind
  title: string
  /** Hanya dirender kalau showDetail=true (halaman pratinjau). */
  detail?: string
  /** Wajib untuk kind="tier": menentukan pips dan warna tepi. */
  tier?: RatingTier
  /** Medal: tingkat 1..5 (Bronze..Onyx). */
  tierLevel?: number
  /** Event/season unik: id untuk memilih siluet + tone deterministik. */
  seed?: string
  /** Event/season unik: monogram pengganti glyph (mis. "MO"). */
  monogram?: string
  state?: AchievementState
  size?: 'sm' | 'md' | 'lg'
  showDetail?: boolean
  onSelect?: () => void
}

// Siluet berbeda supaya tiap event punya bentuk khas. viewBox 0 0 48 60.
const SHAPES = [
  'M24 3 L43 10 V29 C43 42 34.5 50.5 24 55 C13.5 50.5 5 42 5 29 V10 Z', // escutcheon
  'M11 4 H37 Q43 4 43 10 V29 C43 42 34.5 50.5 24 55 C13.5 50.5 5 42 5 29 V10 Q5 4 11 4 Z', // rounded
  'M6 5 H42 V43 L24 56 L6 43 Z', // banner
  'M24 3 L43 12 V34 L24 56 L5 34 V12 Z', // hex
  'M24 3 L42 22 L24 56 L6 22 Z', // kite
  'M44 30 A20 20 0 1 1 4 30 A20 20 0 1 1 44 30 Z', // medallion
] as const

const TIER_SLOTS = 8
const MEDAL_SLOTS = 5

function Glyph({ kind, stroke, fill }: { kind: AchievementKind; stroke: string; fill: string }) {
  switch (kind) {
    case 'tournament':
      return (
        <g fill="none" stroke={stroke} strokeLinejoin="round">
          <path d="M15 13 H33 L27.5 34 H20.5 Z" strokeWidth="2" />
          <path d="M20.2 13 L22.6 34 M27.8 13 L25.4 34" strokeWidth="1.2" />
          <circle cx="24" cy="38" r="4" fill={fill} stroke="none" />
        </g>
      )
    case 'attendance':
      return <path d="M14 26 L21 34 L34 17" fill="none" stroke={stroke} strokeWidth="3.2" strokeLinecap="round" strokeLinejoin="round" />
    case 'volume':
      return (
        <g fill={fill} stroke="none">
          <rect x="14" y="30" width="4.5" height="9" rx="1" />
          <rect x="21.5" y="23" width="4.5" height="16" rx="1" />
          <rect x="29" y="15" width="4.5" height="24" rx="1" />
        </g>
      )
    case 'social':
      return (
        <g fill="none" stroke={stroke} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <circle cx="19" cy="22" r="4" />
          <circle cx="30.5" cy="24.5" r="3.2" />
          <path d="M12.5 39c0-3.6 2.9-5.8 6.5-5.8s6.5 2.2 6.5 5.8" />
          <path d="M26.5 39c0-2.7 1.8-4.5 4-4.5s4 1.8 4 4.5" />
        </g>
      )
    case 'opponent':
      return (
        <g fill="none" stroke={stroke} strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round">
          <path d="M21 18 L14 27 L21 36" />
          <path d="M27 18 L34 27 L27 36" />
        </g>
      )
    case 'season':
      return (
        <g fill="none" stroke={stroke} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <rect x="14" y="18" width="20" height="19" rx="2" />
          <path d="M14 25 H34" />
          <path d="M19 14 V20 M29 14 V20" />
        </g>
      )
    default:
      return (
        <g fill="none" stroke={stroke} strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round">
          <path d="M16 32 L24 24 L32 32" />
          <path d="M16 41 L24 33 L32 41" />
        </g>
      )
  }
}

export default function AchievementBadge({
  kind,
  title,
  detail,
  tier,
  tierLevel,
  seed,
  monogram,
  state = 'earned',
  size = 'md',
  showDetail = false,
  onSelect,
}: AchievementBadgeProps) {
  const locked = state === 'locked'
  const isMedal = !!tierLevel && tierLevel > 0
  const isUnique = !!seed && !isMedal

  const edge = locked
    ? 'var(--color-border)'
    : isMedal
      ? (medalTone(tierLevel) ?? 'var(--color-accent)')
      : isUnique
        ? eventTone(seed)
        : tier
          ? ACHIEVEMENT_TIER_EDGE[tier]
          : 'var(--color-accent)'
  const glyph = locked ? 'var(--color-fg-dim)' : edge
  const shape = isUnique ? SHAPES[eventShape(seed)] : SHAPES[0]
  const shieldW = size === 'lg' ? 72 : size === 'md' ? 52 : 38
  const rank = tier ? TIER_RANK[tier] : 0
  const slots = isMedal ? MEDAL_SLOTS : tier ? TIER_SLOTS : 0
  const filled = isMedal ? tierLevel : rank
  const pip = size === 'lg' ? { w: 6, h: 4, gap: 2.5 } : size === 'md' ? { w: 5, h: 3.5, gap: 2 } : { w: 3.5, h: 2.5, gap: 1.5 }
  const widthClass = size === 'lg' ? 'w-28' : size === 'md' ? 'w-24' : 'w-16'
  const titleClass = size === 'lg' ? 'text-sm' : size === 'md' ? 'text-xs' : 'text-[10px]'
  const monogramSize = size === 'lg' ? 18 : size === 'md' ? 14 : 11

  const emblem = isUnique && monogram ? (
    <text
      x="24"
      y="31"
      textAnchor="middle"
      dominantBaseline="middle"
      fontSize={monogramSize}
      fontWeight="700"
      letterSpacing="0.5"
      fill={glyph}
      opacity={locked ? 0.45 : 1}
    >
      {monogram}
    </text>
  ) : (
    <g opacity={locked ? 0.45 : 1}>
      <Glyph kind={kind} stroke={glyph} fill={glyph} />
    </g>
  )

  const inner = (
    <>
      <svg
        viewBox="0 0 48 60"
        width={shieldW}
        height={Math.round((shieldW * 60) / 48)}
        role="img"
        aria-label={locked ? `${title} (locked)` : title}
      >
        <path
          d={shape}
          fill="var(--color-elevated)"
          stroke={edge}
          strokeWidth="2"
          strokeLinejoin="round"
          strokeDasharray={locked ? '4 3' : undefined}
        />
        {emblem}
      </svg>

      {slots > 0 && (
        <span className="flex items-center justify-center" style={{ gap: pip.gap }} aria-hidden="true">
          {Array.from({ length: slots }, (_, i) => (
            <span
              key={i}
              style={{
                display: 'block',
                width: pip.w,
                height: pip.h,
                borderRadius: 1,
                background: i < (filled ?? 0) ? glyph : 'var(--color-border)',
                opacity: locked ? 0.5 : 1,
              }}
            />
          ))}
        </span>
      )}

      <span className={`block leading-tight ${titleClass} ${locked ? 'text-fg-dim' : 'text-fg'}`}>{title}</span>
      {showDetail && detail && <span className="block text-[10px] text-fg-dim leading-tight">{detail}</span>}
    </>
  )

  if (onSelect) {
    return (
      <button
        type="button"
        onClick={onSelect}
        aria-label={`View ${title} details`}
        className={`flex flex-col items-center gap-1.5 text-center rounded-lg p-1 -m-1 transition-colors hover:bg-elevated/70 active:bg-elevated ${widthClass}`}
      >
        {inner}
      </button>
    )
  }
  return <div className={`flex flex-col items-center gap-1.5 text-center ${widthClass}`}>{inner}</div>
}
