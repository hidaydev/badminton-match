// src/components/ratings/AchievementBadge.tsx, badge medal berbentuk segi enam
// beraturan. Presentasional murni: seluruh isi datang dari props.
//
// Alasan tiap keputusan (R-31):
// - Segi enam beraturan (pointy-top) supaya bisa disusun honeycomb tanpa celah:
//   viewBox-nya persis kotak pembatas heksagon (46.8 x 54 = √3 : 2), sehingga
//   baris ganjil cukup digeser setengah lebar. Satu bentuk untuk semua medal.
// - Tanpa teks (permintaan user): nama + angka muncul di popup detail. Ikon dan
//   warna jadi penanda tunggal. Tiap medal punya glyph sendiri (lihat
//   utils/achievementBadge.medalIcon) supaya tidak ada yang kembar.
// - Milestone dibedakan warna pangkat Bronze..Onyx; event dibedakan tone unik
//   deterministik dari id + monogram nama event.
// - Warna dari token app; satu accent, tanpa gradient/glow/shadow (R-01, R-13).
// - Kalau `onSelect` diberi, root jadi button (keyboard: Tab + Enter/Space).
// - State terkunci dibedakan lewat garis putus + opacity, bukan warna baru
//   (R-29). Tanpa animasi (MOTION 1).

import type { MedalIcon } from '../../utils/achievementBadge'
import { eventTone, hashSeed, medalTone } from '../../utils/achievementBadge'

export type AchievementState = 'earned' | 'locked'

export interface AchievementBadgeProps {
  icon: MedalIcon
  /** Dipakai untuk aria-label, bukan dirender. */
  title: string
  /** Milestone: tingkat 1..5 (Bronze..Onyx) → warna pangkat. */
  tierLevel?: number
  /** Event: id untuk memilih tone + ornamen deterministik. */
  seed?: string
  state?: AchievementState
  /** Lebar heksagon dalam px; tinggi dihitung dari rasio √3:2. */
  width?: number
  onSelect?: () => void
}

// Heksagon beraturan pointy-top, viewBox 0 0 46.8 54.
const SHAPE = 'M23.4 0 L46.8 13.5 V40.5 L23.4 54 L0 40.5 V13.5 Z'
const HEX_RATIO = 54 / 46.8
const CX = 23.4
const CY = 27

// ── Emblem event ──────────────────────────────────────────────────────────
// Event tidak punya ikon tetap, jadi ornamennya digambar dari hash id: motif,
// jumlah elemen, dan rotasinya ikut id, sehingga tiap event tampil beda.

function polyPoints(sides: number, r: number, rotDeg: number): string {
  const pts: string[] = []
  for (let i = 0; i < sides; i++) {
    const a = ((rotDeg + (360 / sides) * i) * Math.PI) / 180
    pts.push(`${(CX + r * Math.cos(a)).toFixed(2)},${(CY + r * Math.sin(a)).toFixed(2)}`)
  }
  return pts.join(' ')
}

function starPoints(points: number, rOuter: number, rInner: number, rotDeg: number): string {
  const pts: string[] = []
  for (let i = 0; i < points * 2; i++) {
    const r = i % 2 === 0 ? rOuter : rInner
    const a = ((rotDeg + (180 / points) * i) * Math.PI) / 180
    pts.push(`${(CX + r * Math.cos(a)).toFixed(2)},${(CY + r * Math.sin(a)).toFixed(2)}`)
  }
  return pts.join(' ')
}

function EventEmblem({ seed, tone }: { seed: string; tone: string }) {
  const h = hashSeed(seed)
  const motif = h % 3
  const rot = h % 30

  if (motif === 0) {
    const points = 6 + ((h >> 3) % 4) // 6..9
    return (
      <g fill="none" stroke={tone} strokeLinejoin="round">
        <polygon points={starPoints(points, 15, 6.5, rot)} strokeWidth="1.8" />
        <circle cx={CX} cy={CY} r="2.2" fill={tone} stroke="none" />
      </g>
    )
  }

  if (motif === 1) {
    const sides = 3 + ((h >> 4) % 3) // 3..5
    return (
      <g fill="none" stroke={tone} strokeLinejoin="round">
        <polygon points={polyPoints(sides, 15, rot)} strokeWidth="1.8" />
        <polygon points={polyPoints(sides, 10.5, rot + 60)} strokeWidth="1.6" />
        <polygon points={polyPoints(sides, 6, rot + 120)} strokeWidth="1.4" />
      </g>
    )
  }

  const spread = ((h >> 5) % 3) + 1 // geser horizontal 1..3
  return (
    <g fill="none" stroke={tone} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
      {[19, 27, 35].map((y, i) => (
        <path key={y} d={`M${CX - 9 + i * spread} ${y} L${CX} ${y - 5} L${CX + 9 - i * spread} ${y}`} />
      ))}
    </g>
  )
}

function Glyph({ icon, stroke, fill }: { icon: MedalIcon; stroke: string; fill: string }) {
  switch (icon) {
    case 'check':
      return <path d="M13 27 L20 34 L34 18" fill="none" stroke={stroke} strokeWidth="3.4" strokeLinecap="round" strokeLinejoin="round" />
    case 'shuttlecock':
      return (
        <g fill="none" stroke={stroke} strokeLinejoin="round">
          <path d="M14.4 15 H32.4 L26.8 33 H20 Z" strokeWidth="2" />
          <path d="M19.8 15 L22.4 33 M27 15 L24.4 33" strokeWidth="1.2" />
          <circle cx="23.4" cy="37.5" r="3.8" fill={fill} stroke="none" />
        </g>
      )
    case 'trophy':
      return (
        <g fill="none" stroke={stroke} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M15.5 14 H31.3 V23.5 C31.3 29.5 27.8 33.5 23.4 33.5 C19 33.5 15.5 29.5 15.5 23.5 Z" />
          <path d="M15.5 16.5 H12.4 C12.4 21 14.2 23.6 16.8 24.4" />
          <path d="M31.3 16.5 H34.4 C34.4 21 32.6 23.6 30 24.4" />
          <path d="M23.4 33.5 V38" />
          <path d="M18 40.5 H28.8" />
        </g>
      )
    case 'arrow-up':
      return (
        <g fill="none" stroke={stroke} strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">
          <path d="M23.4 14 V38" />
          <path d="M15.5 22.5 L23.4 14 L31.3 22.5" />
        </g>
      )
    case 'flame':
      return (
        <path
          d="M23.4 12 C27.5 18 31.5 22.5 31.5 28.5 C31.5 34 28.1 38.5 23.4 38.5 C18.7 38.5 15.3 34 15.3 28.5 C15.3 24.6 17.2 21.6 19.6 18.8 C19.9 22.4 21.3 24.4 23.4 25.8 C22.7 20.6 22.8 16 23.4 12 Z"
          fill={fill}
          stroke="none"
        />
      )
    case 'team':
      return (
        <g fill="none" stroke={stroke} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <circle cx="20.6" cy="23" r="4.2" />
          <circle cx="29.6" cy="25.5" r="3.4" />
          <path d="M13.5 39.5c0-3.8 3-6 7.1-6s7.1 2.2 7.1 6" />
          <path d="M27 39.5c0-2.8 1.9-4.6 4.2-4.6s4.2 1.8 4.2 4.6" />
        </g>
      )
    case 'versus':
      return (
        <g fill="none" stroke={stroke} strokeWidth="3.2" strokeLinecap="round">
          <path d="M15 16 L32 37" />
          <path d="M32 16 L15 37" />
        </g>
      )
    case 'flag':
      return (
        <g fill="none" stroke={stroke} strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M16.5 12 V41" />
          <path d="M16.5 14 H33.5 L29.5 20.5 L33.5 27 H16.5 Z" fill={fill} />
        </g>
      )
    case 'calendar':
      return (
        <g fill="none" stroke={stroke} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <rect x="14.5" y="18" width="18" height="19" rx="2" />
          <path d="M14.5 25 H32.5" />
          <path d="M19 14 V20 M28 14 V20" />
        </g>
      )
  }
}

export default function AchievementBadge({
  icon,
  title,
  tierLevel,
  seed,
  state = 'earned',
  width = 60,
  onSelect,
}: AchievementBadgeProps) {
  const locked = state === 'locked'
  const isMedal = !!tierLevel && tierLevel > 0
  const isEvent = !!seed && !isMedal

  const edge = locked
    ? 'var(--color-border)'
    : isMedal
      ? (medalTone(tierLevel) ?? 'var(--color-accent)')
      : isEvent
        ? eventTone(seed)
        : 'var(--color-accent)'
  const glyph = locked ? 'var(--color-fg-dim)' : edge
  const height = Math.round(width * HEX_RATIO)

  const inner = (
    <svg
      viewBox="0 0 46.8 54"
      width={width}
      height={height}
      role="img"
      aria-label={locked ? `${title} (locked)` : title}
      style={{ display: 'block' }}
    >
      <path
        d={SHAPE}
        fill="var(--color-elevated)"
        stroke={edge}
        strokeWidth="2"
        strokeLinejoin="round"
        strokeDasharray={locked ? '4 3' : undefined}
      />
      {isEvent && seed ? (
        <g opacity={locked ? 0.45 : 1}>
          <EventEmblem seed={seed} tone={glyph} />
        </g>
      ) : (
        <g opacity={locked ? 0.45 : 1}>
          <Glyph icon={icon} stroke={glyph} fill={glyph} />
        </g>
      )}
    </svg>
  )

  if (onSelect) {
    return (
      <button
        type="button"
        onClick={onSelect}
        aria-label={`View ${title} details`}
        className="rounded transition-transform hover:scale-105 active:scale-95 focus-visible:outline-none"
        style={{ width, height }}
      >
        {inner}
      </button>
    )
  }
  return inner
}
