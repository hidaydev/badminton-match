// src/components/ratings/AchievementBadge.tsx, badge medal berbentuk segi enam
// beraturan dengan visual metalik prestisius dan taktil ("ciamik").
//
// Alasan tiap keputusan (R-31):
// - Segi enam beraturan (pointy-top) dipertahankan 100%:
//   viewBox-nya persis kotak pembatas heksagon (46.8 x 54 = √3 : 2), sehingga
//   packing sarang lebah (MedalHoneycomb) tetap rapat dan presisi tanpa celah.
// - Visual metalik taktil bertingkat (Bronze, Silver, Gold, Platinum, Onyx):
//   gradien metalik directional (highlight, core, rim-bounce), dual-ring beveled
//   edge (outer chamfer + inner facet), dan relief embos pada glyph di pelat tengah.
// - Event medals mendapat seal/emblem geometris berdimensi (faceted star, laurel,
//   rosette, diamond crest) dengan tone warna unik per turnamen.
// - State terkunci: siluet dark frosted / etched obsidian taktil.
// - Micro-interaksi: hover scale springy + ambient glow senada warna tier.

import { useId } from 'react'
import type { MedalIcon } from '../../utils/achievementBadge'
import { eventTone, hashSeed } from '../../utils/achievementBadge'
import {
  getEventMedalStyle,
  MEDAL_TIER_STYLES,
  type MedalTierStyle,
} from '../../config/achievements'

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

const HEX_RATIO = 54 / 46.8
const CX = 23.4
const CY = 27
const COS30 = 0.8660254037844386

// Menghitung koordinat 6 titik segi enam pointy-top untuk radius r tertentu
function hexPoints(r: number, cx = CX, cy = CY): [number, number][] {
  return [
    [cx, cy - r],                  // 0: atas
    [cx + r * COS30, cy - r * 0.5], // 1: kanan atas
    [cx + r * COS30, cy + r * 0.5], // 2: kanan bawah
    [cx, cy + r],                  // 3: bawah
    [cx - r * COS30, cy + r * 0.5], // 4: kiri bawah
    [cx - r * COS30, cy - r * 0.5], // 5: kiri atas
  ]
}

function hexPath(r: number, cx = CX, cy = CY): string {
  const p = hexPoints(r, cx, cy)
  return `M${p[0][0].toFixed(2)} ${p[0][1].toFixed(2)} L${p[1][0].toFixed(2)} ${p[1][1].toFixed(2)} L${p[2][0].toFixed(2)} ${p[2][1].toFixed(2)} L${p[3][0].toFixed(2)} ${p[3][1].toFixed(2)} L${p[4][0].toFixed(2)} ${p[4][1].toFixed(2)} L${p[5][0].toFixed(2)} ${p[5][1].toFixed(2)} Z`
}

// ── Dimensional Event Seals (Procedural Geometric Emblems) ────────────────
function DimensionalStar({
  points,
  rOuter,
  rInner,
  rot,
  lightGrad,
  darkGrad,
}: {
  points: number
  rOuter: number
  rInner: number
  rot: number
  lightGrad: string
  darkGrad: string
}) {
  const facets: { light: string; dark: string }[] = []
  const step = 360 / points
  const halfStep = step / 2

  for (let i = 0; i < points; i++) {
    const aPeak = ((rot + i * step - 90) * Math.PI) / 180
    const aLeft = ((rot + i * step - halfStep - 90) * Math.PI) / 180
    const aRight = ((rot + i * step + halfStep - 90) * Math.PI) / 180

    const pPeak = `${(CX + rOuter * Math.cos(aPeak)).toFixed(2)},${(CY + rOuter * Math.sin(aPeak)).toFixed(2)}`
    const pLeft = `${(CX + rInner * Math.cos(aLeft)).toFixed(2)},${(CY + rInner * Math.sin(aLeft)).toFixed(2)}`
    const pRight = `${(CX + rInner * Math.cos(aRight)).toFixed(2)},${(CY + rInner * Math.sin(aRight)).toFixed(2)}`
    const pCenter = `${CX.toFixed(2)},${CY.toFixed(2)}`

    facets.push({
      light: `M${pCenter} L${pLeft} L${pPeak} Z`,
      dark: `M${pCenter} L${pPeak} L${pRight} Z`,
    })
  }

  return (
    <g>
      {facets.map((f, i) => (
        <g key={i}>
          <path d={f.light} fill={`url(#${lightGrad})`} />
          <path d={f.dark} fill={`url(#${darkGrad})`} />
        </g>
      ))}
      <circle cx={CX} cy={CY} r="2.6" fill={`url(#${lightGrad})`} />
      <circle cx={CX - 0.7} cy={CY - 0.7} r="0.9" fill="#ffffff" opacity="0.8" />
    </g>
  )
}

function EventEmblem({
  seed,
  lightGrad,
  darkGrad,
  glyphGrad,
  specular,
}: {
  seed: string
  lightGrad: string
  darkGrad: string
  glyphGrad: string
  specular: string
}) {
  const h = hashSeed(seed)
  const motif = h % 4
  const rot = (h >> 3) % 45

  // Motif 0: Dimensional Faceted Star (8-point) with compass ring
  if (motif === 0) {
    return (
      <g>
        <circle
          cx={CX}
          cy={CY}
          r="14.8"
          fill="none"
          stroke={`url(#${glyphGrad})`}
          strokeWidth="0.8"
          strokeDasharray="1.2 2"
          opacity="0.75"
        />
        <DimensionalStar
          points={8}
          rOuter={13.2}
          rInner={4.8}
          rot={rot}
          lightGrad={lightGrad}
          darkGrad={darkGrad}
        />
      </g>
    )
  }

  // Motif 1: Championship Laurel & Dimensional 6-point Star
  if (motif === 1) {
    return (
      <g>
        {/* Geometric Laurel Arcs */}
        <path
          d={`M${CX - 13.5} ${CY - 2} C${CX - 15} ${CY + 8}, ${CX - 7} ${CY + 14}, ${CX} ${CY + 14} C${CX + 7} ${CY + 14}, ${CX + 15} ${CY + 8}, ${CX + 13.5} ${CY - 2}`}
          fill="none"
          stroke={`url(#${glyphGrad})`}
          strokeWidth="1.6"
          strokeLinecap="round"
        />
        <path
          d={`M${CX - 14} ${CY + 4} L${CX - 11} ${CY + 3} M${CX - 11} ${CY + 9} L${CX - 8} ${CY + 8} M${CX + 14} ${CY + 4} L${CX + 11} ${CY + 3} M${CX + 11} ${CY + 9} L${CX + 8} ${CY + 8}`}
          stroke={`url(#${glyphGrad})`}
          strokeWidth="1.2"
          strokeLinecap="round"
        />
        <DimensionalStar
          points={6}
          rOuter={10.5}
          rInner={4.2}
          rot={rot}
          lightGrad={lightGrad}
          darkGrad={darkGrad}
        />
      </g>
    )
  }

  // Motif 2: Imperial Rosette / Sunburst (12-point faceted burst)
  if (motif === 2) {
    return (
      <g>
        <circle
          cx={CX}
          cy={CY}
          r="15"
          fill="none"
          stroke={specular}
          strokeWidth="0.6"
          opacity="0.4"
        />
        <DimensionalStar
          points={12}
          rOuter={13.6}
          rInner={7.2}
          rot={rot}
          lightGrad={lightGrad}
          darkGrad={darkGrad}
        />
        <circle
          cx={CX}
          cy={CY}
          r="4.6"
          fill="none"
          stroke={`url(#${glyphGrad})`}
          strokeWidth="1"
        />
        <circle cx={CX} cy={CY} r="2.2" fill={`url(#${lightGrad})`} />
      </g>
    )
  }

  // Motif 3: Tournament Hexagon Gem with Layered Chevrons
  return (
    <g>
      <polygon
        points={hexPoints(14.2)
          .map((pt) => `${pt[0].toFixed(2)},${pt[1].toFixed(2)}`)
          .join(' ')}
        fill="none"
        stroke={`url(#${glyphGrad})`}
        strokeWidth="1.2"
        strokeLinejoin="round"
      />
      <polygon
        points={hexPoints(9.8, CX, CY)
          .map((pt) => `${pt[0].toFixed(2)},${pt[1].toFixed(2)}`)
          .join(' ')}
        fill={`url(#${darkGrad})`}
        stroke={`url(#${lightGrad})`}
        strokeWidth="1"
        strokeLinejoin="round"
      />
      <DimensionalStar
        points={6}
        rOuter={7.5}
        rInner={3.2}
        rot={rot + 30}
        lightGrad={lightGrad}
        darkGrad={darkGrad}
      />
    </g>
  )
}

// ── Milestone Glyph Renderers ─────────────────────────────────────────────
function Glyph({
  icon,
  glyphGrad,
  specular,
}: {
  icon: MedalIcon
  glyphGrad: string
  specular: string
}) {
  const stroke = `url(#${glyphGrad})`
  const fill = stroke

  switch (icon) {
    case 'check':
      return (
        <path
          d="M13 27 L20 34 L34 18"
          fill="none"
          stroke={stroke}
          strokeWidth="3.4"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      )

    case 'shuttlecock':
      return (
        <g fill="none" stroke={stroke} strokeLinejoin="round">
          {/* Feather cage with subtle translucent body fill */}
          <path
            d="M14.4 15 H32.4 L26.8 33 H20 Z"
            strokeWidth="2"
            fill={stroke}
            fillOpacity="0.12"
          />
          <path d="M19.8 15 L22.4 33 M27 15 L24.4 33" strokeWidth="1.2" />
          <path d="M16.5 24 H30.3" strokeWidth="1.2" />
          {/* Solid rounded cork */}
          <circle cx="23.4" cy="37.5" r="3.8" fill={fill} stroke="none" />
          <circle cx="22.2" cy="36.3" r="1" fill={specular} opacity="0.75" />
        </g>
      )

    case 'trophy':
      return (
        <g fill="none" stroke={stroke} strokeLinecap="round" strokeLinejoin="round">
          {/* Cup bowl with subtle gilded fill */}
          <path
            d="M15.5 14 H31.3 V23.5 C31.3 29.5 27.8 33.5 23.4 33.5 C19 33.5 15.5 29.5 15.5 23.5 Z"
            strokeWidth="2"
            fill={stroke}
            fillOpacity="0.18"
          />
          {/* Left & Right handles */}
          <path d="M15.5 16.5 H12.4 C12.4 21 14.2 23.6 16.8 24.4" strokeWidth="1.8" />
          <path d="M31.3 16.5 H34.4 C34.4 21 32.6 23.6 30 24.4" strokeWidth="1.8" />
          {/* Stem & Pedestal Base */}
          <path d="M23.4 33.5 V38" strokeWidth="2.2" />
          <path d="M17.5 40.5 H29.3" strokeWidth="2.4" />
        </g>
      )

    case 'flame':
      return (
        <g>
          {/* Outer flame */}
          <path
            d="M23.4 12 C27.5 18 31.5 22.5 31.5 28.5 C31.5 34 28.1 38.5 23.4 38.5 C18.7 38.5 15.3 34 15.3 28.5 C15.3 24.6 17.2 21.6 19.6 18.8 C19.9 22.4 21.3 24.4 23.4 25.8 C22.7 20.6 22.8 16 23.4 12 Z"
            fill={fill}
          />
          {/* Inner core flame */}
          <path
            d="M23.4 22 C25.5 26 27 28.5 27 32 C27 35.5 25.4 37 23.4 37 C21.4 37 19.8 35.5 19.8 32 C19.8 29.5 21 27 22 25 Z"
            fill={specular}
            opacity="0.65"
          />
        </g>
      )

    case 'team':
      return (
        <g fill="none" stroke={stroke} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <circle cx="20.6" cy="23" r="4.2" fill={stroke} fillOpacity="0.2" />
          <circle cx="29.6" cy="25.5" r="3.4" fill={stroke} fillOpacity="0.2" />
          <path d="M13.5 39.5c0-3.8 3-6 7.1-6s7.1 2.2 7.1 6" />
          <path d="M27 39.5c0-2.8 1.9-4.6 4.2-4.6s4.2 1.8 4.2 4.6" />
        </g>
      )

    case 'versus':
      return (
        <g stroke={stroke} strokeLinecap="round">
          <path d="M15 16 L32 37" strokeWidth="3.4" />
          <path d="M32 16 L15 37" strokeWidth="3.4" />
          <circle cx={CX} cy={CY} r="2.8" fill={fill} stroke="none" />
        </g>
      )

    case 'flag':
      return (
        <g fill="none" stroke={stroke} strokeLinecap="round" strokeLinejoin="round">
          <path d="M16.5 12 V41" strokeWidth="2.4" />
          <path d="M16.5 14 H33.5 L29.5 20.5 L33.5 27 H16.5 Z" fill={fill} strokeWidth="2" />
        </g>
      )

    case 'podium':
      return (
        <g fill="none" stroke={stroke} strokeWidth="2" strokeLinejoin="round">
          <rect x="13" y="27" width="6.8" height="11" fill={stroke} fillOpacity="0.15" />
          <rect x="19.8" y="20" width="6.8" height="18" fill={fill} />
          <rect x="26.6" y="30.5" width="6.8" height="7.5" fill={stroke} fillOpacity="0.15" />
          <path d="M11.5 39 H35.5" strokeWidth="2.2" strokeLinecap="round" />
        </g>
      )

    case 'stairup':
      return (
        <g fill="none" stroke={stroke} strokeLinecap="round" strokeLinejoin="round">
          <path d="M13.5 39.5 H21 V33 H28.5 V26.5 H36" strokeWidth="2.4" />
          <path d="M31 22 L36 26.5 L31 31" strokeWidth="2.4" />
        </g>
      )
  }
}

// ── Main Component ────────────────────────────────────────────────────────
export default function AchievementBadge({
  icon,
  title,
  tierLevel,
  seed,
  state = 'earned',
  width = 60,
  onSelect,
}: AchievementBadgeProps) {
  const rawId = useId()
  const id = `ach-${rawId.replace(/[^a-zA-Z0-9_-]/g, '_')}`

  const locked = state === 'locked'
  const isMedal = !!tierLevel && tierLevel > 0
  const isEvent = !!seed && !isMedal

  // Mendapatkan palet gaya metalik berdasarkan tier atau event
  let style: MedalTierStyle
  if (locked) {
    style = {
      level: 0,
      name: 'Locked',
      tone: '#596575',
      rimStops: ['#475262', '#36404e', '#27303c', '#171c24', '#2a3442'],
      faceStops: ['#171b23', '#0a0d11'],
      glyphStops: ['#4b5768', '#384352', '#262f3a'],
      specular: '#64748b',
      glow: 'rgba(255, 255, 255, 0.05)',
      pillBg: 'bg-slate-900',
      pillText: 'text-fg-dim',
      pillBorder: 'border-border',
    }
  } else if (isMedal) {
    const tierIdx = Math.max(0, Math.min(MEDAL_TIER_STYLES.length - 1, tierLevel - 1))
    style = MEDAL_TIER_STYLES[tierIdx]
  } else if (isEvent && seed) {
    const tone = eventTone(seed)
    style = getEventMedalStyle(tone)
  } else {
    // Default fallback ke Gold style
    style = MEDAL_TIER_STYLES[2]
  }

  const height = Math.round(width * HEX_RATIO)

  // Geometri cincin konsentris heksagon
  const pOuter = hexPoints(26.2)
  const pathOuter = hexPath(26.2)
  const pathBevel = hexPath(22.8)
  const pFace = hexPoints(21.0)
  const pathFace = hexPath(21.0)
  const pathInnerGroove = hexPath(19.4)

  // Highlight facet atas (pantulan cahaya specular)
  const upperFacetPath = `M${pOuter[4][0].toFixed(2)} ${pOuter[4][1].toFixed(2)} L${pOuter[5][0].toFixed(2)} ${pOuter[5][1].toFixed(2)} L${pOuter[0][0].toFixed(2)} ${pOuter[0][1].toFixed(2)} L${pOuter[1][0].toFixed(2)} ${pOuter[1][1].toFixed(2)}`
  // Shadow facet bawah (bayangan tebal bevel rim)
  const lowerFacetPath = `M${pOuter[1][0].toFixed(2)} ${pOuter[1][1].toFixed(2)} L${pOuter[2][0].toFixed(2)} ${pOuter[2][1].toFixed(2)} L${pOuter[3][0].toFixed(2)} ${pOuter[3][1].toFixed(2)} L${pOuter[4][0].toFixed(2)} ${pOuter[4][1].toFixed(2)}`

  // Inner face recessed shadow & highlight
  const innerUpperShadow = `M${pFace[4][0].toFixed(2)} ${pFace[4][1].toFixed(2)} L${pFace[5][0].toFixed(2)} ${pFace[5][1].toFixed(2)} L${pFace[0][0].toFixed(2)} ${pFace[0][1].toFixed(2)} L${pFace[1][0].toFixed(2)} ${pFace[1][1].toFixed(2)}`
  const innerLowerReflect = `M${pFace[1][0].toFixed(2)} ${pFace[1][1].toFixed(2)} L${pFace[2][0].toFixed(2)} ${pFace[2][1].toFixed(2)} L${pFace[3][0].toFixed(2)} ${pFace[3][1].toFixed(2)} L${pFace[4][0].toFixed(2)} ${pFace[4][1].toFixed(2)}`

  const innerSvg = (
    <svg
      viewBox="0 0 46.8 54"
      width={width}
      height={height}
      role="img"
      aria-label={locked ? `${title} (locked)` : title}
      style={{ display: 'block', overflow: 'visible' }}
    >
      <defs>
        {/* Outer Rim Metallic Linear Gradient (135 deg light source) */}
        <linearGradient id={`${id}-rim`} x1="15%" y1="0%" x2="85%" y2="100%">
          <stop offset="0%" stopColor={style.rimStops[0]} />
          <stop offset="25%" stopColor={style.rimStops[1]} />
          <stop offset="50%" stopColor={style.rimStops[2]} />
          <stop offset="75%" stopColor={style.rimStops[3]} />
          <stop offset="100%" stopColor={style.rimStops[4]} />
        </linearGradient>

        {/* Inner Plate Dark Metallic Radial Gradient */}
        <radialGradient id={`${id}-face`} cx="42%" cy="36%" r="65%">
          <stop offset="0%" stopColor={style.faceStops[0]} />
          <stop offset="100%" stopColor={style.faceStops[1]} />
        </radialGradient>

        {/* Central Glyph Metallic Gradient */}
        <linearGradient id={`${id}-glyph`} x1="0%" y1="0%" x2="0%" y2="100%">
          <stop offset="0%" stopColor={style.glyphStops[0]} />
          <stop offset="50%" stopColor={style.glyphStops[1]} />
          <stop offset="100%" stopColor={style.glyphStops[2]} />
        </linearGradient>

        {/* Event Seal Facet Gradients */}
        <linearGradient id={`${id}-light`} x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" stopColor={style.specular} />
          <stop offset="100%" stopColor={style.tone} />
        </linearGradient>
        <linearGradient id={`${id}-dark`} x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" stopColor={style.tone} />
          <stop offset="100%" stopColor={style.rimStops[3]} />
        </linearGradient>

        {/* Translucent Specular Glare Arc */}
        <linearGradient id={`${id}-sheen`} x1="0%" y1="0%" x2="0%" y2="100%">
          <stop offset="0%" stopColor={style.specular} stopOpacity="0.32" />
          <stop offset="100%" stopColor={style.specular} stopOpacity="0" />
        </linearGradient>

        {/* Tactile Emboss / Drop Shadow for Central Relief */}
        <filter id={`${id}-relief`} x="-20%" y="-20%" width="140%" height="140%">
          <feDropShadow dx="0" dy="1.1" stdDeviation="0.75" floodColor="#000000" floodOpacity="0.75" />
        </filter>
      </defs>

      {/* ── 1. Outer Beveled Rim ────────────────────────────────────── */}
      <path
        d={pathOuter}
        fill={`url(#${id}-rim)`}
        stroke="#000000"
        strokeWidth="0.8"
        strokeLinejoin="round"
      />

      {/* Outer specular rim highlight (upper facets) */}
      <path
        d={upperFacetPath}
        fill="none"
        stroke={style.specular}
        strokeWidth="0.9"
        strokeLinecap="round"
        strokeLinejoin="round"
        opacity={locked ? 0.4 : 0.85}
      />
      {/* Outer deep rim shadow (lower facets) */}
      <path
        d={lowerFacetPath}
        fill="none"
        stroke="#000000"
        strokeWidth="1.1"
        strokeLinecap="round"
        strokeLinejoin="round"
        opacity="0.6"
      />

      {/* ── 2. Inner Bevel Groove / Dual-Ring Step ─────────────────── */}
      <path
        d={pathBevel}
        fill="none"
        stroke="#000000"
        strokeWidth="1"
        strokeLinejoin="round"
        opacity="0.45"
      />

      {/* ── 3. Medallion Face Plate ─────────────────────────────────── */}
      <path
        d={pathFace}
        fill={`url(#${id}-face)`}
        stroke={locked ? '#2a323f' : style.rimStops[1]}
        strokeWidth="0.75"
        strokeLinejoin="round"
      />

      {/* Recessed top-left inner shadow */}
      <path
        d={innerUpperShadow}
        fill="none"
        stroke="#000000"
        strokeWidth="0.8"
        strokeLinecap="round"
        strokeLinejoin="round"
        opacity="0.55"
      />
      {/* Recessed bottom-right inner reflection */}
      <path
        d={innerLowerReflect}
        fill="none"
        stroke={style.specular}
        strokeWidth="0.75"
        strokeLinecap="round"
        strokeLinejoin="round"
        opacity={locked ? 0.2 : 0.4}
      />

      {/* Subtle Minted Coin Facet Lines */}
      {pFace.map((pt, i) => (
        <line
          key={i}
          x1={CX}
          y1={CY}
          x2={pt[0]}
          y2={pt[1]}
          stroke={style.tone}
          strokeWidth="0.5"
          opacity={locked ? 0.06 : 0.12}
        />
      ))}

      {/* Inner Decorative Hex Ring */}
      <path
        d={pathInnerGroove}
        fill="none"
        stroke={style.tone}
        strokeWidth="0.6"
        strokeLinejoin="round"
        strokeDasharray={locked ? '2.5 2' : undefined}
        opacity={locked ? 0.35 : 0.2}
      />

      {/* Top Specular Sheen Arc */}
      {!locked && (
        <path
          d={`M${pFace[5][0].toFixed(2)} ${pFace[5][1].toFixed(2)} Q${CX} ${CY - 8} ${pFace[1][0].toFixed(2)} ${pFace[1][1].toFixed(2)} L${pFace[0][0].toFixed(2)} ${pFace[0][1].toFixed(2)} Z`}
          fill={`url(#${id}-sheen)`}
        />
      )}

      {/* ── 4. Center Glyph / Procedural Seal ───────────────────────── */}
      <g filter={`url(#${id}-relief)`} opacity={locked ? 0.45 : 1}>
        {isEvent && seed ? (
          <EventEmblem
            seed={seed}
            lightGrad={`${id}-light`}
            darkGrad={`${id}-dark`}
            glyphGrad={`${id}-glyph`}
            specular={style.specular}
          />
        ) : (
          <Glyph
            icon={icon}
            glyphGrad={`${id}-glyph`}
            specular={style.specular}
          />
        )}
      </g>
    </svg>
  )

  if (onSelect) {
    return (
      <button
        type="button"
        onClick={onSelect}
        aria-label={`View ${title} details`}
        className="medal-badge-btn cursor-pointer select-none rounded focus-visible:outline-none"
        style={{
          width,
          height,
          ['--medal-glow' as string]: style.glow,
        }}
      >
        {innerSvg}
      </button>
    )
  }

  return (
    <div
      style={{
        width,
        height,
        display: 'inline-block',
        ['--medal-glow' as string]: style.glow,
      }}
    >
      {innerSvg}
    </div>
  )
}
