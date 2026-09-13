// src/components/ratings/AchievementBadge.tsx, badge koleksi achievement
// berbentuk shield/patch. Presentasional murni: seluruh isi datang dari props,
// tidak ada data contoh di dalam komponen.
//
// Alasan tiap keputusan (R-31):
// - Shield/patch: menandai "pencapaian terkumpul", beda dari chip tier yang
//   sudah ada (RatingTierBadge). Bentuknya badge, bukan label status.
// - Warna ambil token app; badge tier memakai ramp bronze ke gold dari config
//   supaya tingkat makin kuat warnanya. Satu accent, tanpa gradient/glow/shadow
//   (R-01, R-13).
// - Glyph relevan ke makna (R-04): shuttlecock = ikut turnamen, dua chevron
//   naik = breakthrough tier. Bukan ikon generik.
// - Pips (8 slot) menunjukkan tingkat tier: terisi = sudah dicapai, kosong =
//   sisa tangga. Memberi pembeda visual antar tier, bukan cuma teks.
// - State terkunci dibedakan lewat garis putus + opacity, bukan warna baru
//   (R-29). Tanpa animasi (MOTION 1).

import { ACHIEVEMENT_TIER_EDGE, TIER_RANK, type RatingTier } from '../../config/ratingTiers'

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
  /** Baris kecil di bawah judul, mis. nama season atau tier asal. */
  detail?: string
  /** Wajib untuk kind="tier": menentukan pips dan warna tepi. */
  tier?: RatingTier
  state?: AchievementState
  size?: 'sm' | 'md'
}

// Escutcheon: sisi atas rata, bawah meruncing. viewBox 0 0 48 60.
const SHIELD = 'M24 3 L43 10 V29 C43 42 34.5 50.5 24 55 C13.5 50.5 5 42 5 29 V10 Z'
const TIER_SLOTS = 8

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
  state = 'earned',
  size = 'md',
}: AchievementBadgeProps) {
  const locked = state === 'locked'
  const edge = locked
    ? 'var(--color-border)'
    : tier
      ? ACHIEVEMENT_TIER_EDGE[tier]
      : 'var(--color-accent)'
  const glyph = locked ? 'var(--color-fg-dim)' : edge
  const shieldW = size === 'md' ? 52 : 38
  const rank = tier ? TIER_RANK[tier] : 0

  return (
    <figure className={`flex flex-col items-center gap-1.5 text-center ${size === 'md' ? 'w-24' : 'w-16'}`}>
      <svg
        viewBox="0 0 48 60"
        width={shieldW}
        height={Math.round((shieldW * 60) / 48)}
        role="img"
        aria-label={locked ? `${title} (belum terbuka)` : title}
      >
        <path
          d={SHIELD}
          fill="var(--color-elevated)"
          stroke={edge}
          strokeWidth="2"
          strokeLinejoin="round"
          strokeDasharray={locked ? '4 3' : undefined}
        />
        <g opacity={locked ? 0.45 : 1}>
          <Glyph kind={kind} stroke={glyph} fill={glyph} />
        </g>
      </svg>

      {kind === 'tier' && tier && (
        <div className="flex items-center justify-center" style={{ gap: size === 'md' ? 2 : 1.5 }} aria-hidden="true">
          {Array.from({ length: TIER_SLOTS }, (_, i) => (
            <span
              key={i}
              style={{
                width: size === 'md' ? 5 : 3.5,
                height: size === 'md' ? 3.5 : 2.5,
                borderRadius: 1,
                background: i < rank ? glyph : 'var(--color-border)',
                opacity: locked ? 0.5 : 1,
              }}
            />
          ))}
        </div>
      )}

      <figcaption>
        <span
          className={`block leading-tight ${size === 'md' ? 'text-xs' : 'text-[10px]'} ${
            locked ? 'text-fg-dim' : 'text-fg'
          }`}
        >
          {title}
        </span>
        {detail && <span className="block text-[10px] text-fg-dim mt-0.5 leading-tight">{detail}</span>}
      </figcaption>
    </figure>
  )
}
