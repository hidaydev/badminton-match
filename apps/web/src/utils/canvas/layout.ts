// Pure layout for the social exports.
//
// Every composition is one function that returns explicit geometry: boxes,
// baselines, font sizes, rotations and the final (already truncated) strings.
// The matching draw in `draw.ts` only paints what it finds here, so an
// assertion on a layout is an assertion on the rendering.
//
// All offsets are the v1 numbers written on the 1080x1350 design grid and
// multiplied by the configured canvas: `sx` for anything horizontal or
// typographic, `sy` for vertical offsets. Nothing is hardcoded to 1080.

import type { CanvasSize, Point, Rect } from './geometry'
import { box, boxCenter, DESIGN, transformedBounds, unionBounds } from './geometry'
import type { ExportDimensions } from './dimensions'
import {
  ACCENT,
  BG_DARK,
  BORDER,
  BRAND,
  CLASSIC_SURFACE,
  DIVIDER,
  GROUP_SURFACE,
  MUTED,
  MONTH_ROTATION_DEG,
  ROAD_RAGE_SKEW_DEG,
  TEAM_BASE,
  TEAM_PANEL,
  TEXT,
  YEAR_PLATE_ROTATION_DEG,
  CANVAS_COLORS,
} from './palette'
import type { TextBlock, TextMeasure } from './text'
import {
  canvasMeasureText,
  edoszFont,
  monoFont,
  ordinal,
  roadRageFont,
  sansFont,
  textBlock,
} from './text'

export type Variant = 'post' | 'story'

type Frame = { sx: number; sy: number }

function frameOf(canvas: CanvasSize): Frame {
  return { sx: canvas.width / DESIGN.width, sy: canvas.height / DESIGN.height }
}

/** The configured canvas for one variant. */
export function resolveCanvas(
  dimensions: ExportDimensions,
  variant: Variant,
): CanvasSize {
  return variant === 'story' ? dimensions.story : dimensions.post
}

/** A rectangle plus the transform that places it. */
export type RotatedRect = { rect: Rect; rotation: number; pivot: Point }

// ── Header band ──────────────────────────────────────────────────────────────

export const HEADER_HEIGHT = 90
export const HEADER_LOGO_HEIGHT = 28
export const TOURNAMENT_LABEL = 'MAJADU INTERNAL TOURNAMENT 2026'

const HEADER_FONT = 15
const HEADER_LETTER_SPACING = 1.5
const HEADER_CENTER_PAD = 30
const HEADER_LOGO_FALLBACK_WIDTH = 160
const HEADER_GRADIENT = { from: 'rgba(10,10,20,0.92)', to: 'rgba(0,0,0,0)' }
const HEADER_SEGMENTS = [
  { text: 'MAJADU FUN', color: CANVAS_COLORS.white },
  { text: '  \u2022  ', color: ACCENT },
  { text: 'MAJADU FUN', color: CANVAS_COLORS.white },
  { text: '  \u2022  ', color: ACCENT },
  { text: 'MAJADU FUN', color: CANVAS_COLORS.white },
] as const

export type HeaderLayout = {
  rect: Rect
  gradient: { from: string; to: string }
  logo: Rect | null
  texts: TextBlock[]
}

export type HeaderInput = {
  canvas: CanvasSize
  /** One label mirrored on both sides; `null` repeats the session text. */
  label?: string | null
  /** width / height of the logo, when one is loaded. */
  logoAspect?: number | null
  measure?: TextMeasure
}

/** v1 `drawHeader`: gradient band, logo in the middle, text on both sides. */
export function headerLayout(input: HeaderInput): HeaderLayout {
  const measure = input.measure ?? canvasMeasureText
  const { sx } = frameOf(input.canvas)
  const width = input.canvas.width
  const height = HEADER_HEIGHT * sx
  const logoHeight = HEADER_LOGO_HEIGHT * sx
  const fontSize = HEADER_FONT * sx
  const letterSpacing = HEADER_LETTER_SPACING * sx
  const centerPad = HEADER_CENTER_PAD * sx
  const logoWidth =
    input.logoAspect == null
      ? HEADER_LOGO_FALLBACK_WIDTH * sx
      : logoHeight * input.logoAspect
  const textY = height / 2 + fontSize * 0.38
  const font = sansFont(fontSize, 'bold')
  const texts: TextBlock[] = []

  if (input.label != null) {
    const leftX = (width - logoWidth) / 2 - centerPad
    const rightX = (width + logoWidth) / 2 + centerPad
    texts.push(
      textBlock({
        text: input.label,
        font,
        size: fontSize,
        color: CANVAS_COLORS.white,
        x: leftX,
        y: textY,
        align: 'right',
        letterSpacing,
        measure,
      }),
      textBlock({
        text: input.label,
        font,
        size: fontSize,
        color: CANVAS_COLORS.white,
        x: rightX,
        y: textY,
        align: 'left',
        letterSpacing,
        measure,
      }),
    )
  } else {
    const sideZone = (width - logoWidth) / 2 - centerPad
    const total = HEADER_SEGMENTS.reduce(
      (sum, segment) => sum + measure(segment.text, font),
      0,
    )
    const clamped = Math.min(total, sideZone)
    const starts = [
      (width - logoWidth) / 2 - centerPad - clamped,
      (width + logoWidth) / 2 + centerPad,
    ]
    for (const start of starts) {
      let x = start
      for (const segment of HEADER_SEGMENTS) {
        texts.push(
          textBlock({
            text: segment.text,
            font,
            size: fontSize,
            color: segment.color,
            x,
            y: textY,
            letterSpacing,
            measure,
          }),
        )
        x += measure(segment.text, font)
      }
    }
  }

  return {
    rect: box(0, 0, width, height),
    gradient: HEADER_GRADIENT,
    logo: box((width - logoWidth) / 2, (height - logoHeight) / 2, logoWidth, logoHeight),
    texts,
  }
}

// ── Date overlay ─────────────────────────────────────────────────────────────

const DATE = {
  daySize: 200,
  monthSize: 82,
  yearSize: 72,
  topY: 150,
  columnGap: 16,
  monthGap: 14,
  brushGap: 4,
  dayOffsetX: 15,
  dayOffsetY: 15,
  shadowOffsetX: 5,
  shadowOffsetY: 20,
  monthOffsetX: 24,
  monthOffsetY: 30,
  monthStroke: 10,
  platePadX: 160,
  platePadY: 110,
  plateOffsetY: 10,
  yearLift: 5,
  yearBaselineRatio: 0.22,
  lineHeight: 0.88,
  yearPad: 22,
  yearGap: 30,
  columnPad: 20,
} as const

export type DateOverlayLayout = {
  canvas: CanvasSize
  day: { fill: TextBlock; shadow: TextBlock }
  month: { text: TextBlock; strokeColor: string; strokeWidth: number }
  yearPlate: {
    rect: Rect
    rotation: number
    pivot: Point
    fill: string
    year: TextBlock
    bounds: Rect
  }
  bounds: Rect
}

export type DateOverlayInput = {
  dimensions: ExportDimensions
  variant: Variant
  day: string
  month: string
  year: string
  measure?: TextMeasure
}

/**
 * v1 `drawDate`: day in the display face, month leaning the other way, year on
 * a brush-stroke plate. Granesta is gone, so the day and the month use Road
 * Rage with a -9 degree skew to keep the v1 posture; the year stays Edosz.
 */
export function dateOverlayLayout(input: DateOverlayInput): DateOverlayLayout {
  const measure = input.measure ?? canvasMeasureText
  const canvas = resolveCanvas(input.dimensions, input.variant)
  const { sx, sy } = frameOf(canvas)
  const width = canvas.width
  const daySize = DATE.daySize * sx
  const monthSize = DATE.monthSize * sx
  const yearSize = DATE.yearSize * sx
  const skewX = Math.tan((ROAD_RAGE_SKEW_DEG * Math.PI) / 180)

  const dayWidth = measure(input.day, roadRageFont(daySize))
  const monthWidth = measure(input.month, roadRageFont(monthSize))
  const yearWidth = measure(input.year, edoszFont(yearSize))

  const rightColumnWidth =
    Math.max(monthWidth, yearWidth + DATE.yearGap * sx) + DATE.columnPad * sx
  const gap = DATE.columnGap * sx
  const startX = (width - (dayWidth + gap + rightColumnWidth)) / 2
  const rightColumnX = startX + dayWidth + gap

  const dayHeight = daySize * DATE.lineHeight
  const monthHeight = monthSize * DATE.lineHeight
  const brushHeight = yearSize + DATE.yearPad * sx
  const rightColumnHeight = monthHeight + DATE.monthGap * sx + brushHeight
  const columnHeight = Math.max(dayHeight, rightColumnHeight)
  const topY = DATE.topY * sy

  const dayBaseline = topY + columnHeight / 2 + dayHeight / 2
  const rightColumnTop = topY + (columnHeight - rightColumnHeight) / 2
  const monthBaseline = rightColumnTop + monthHeight
  const brushY = monthBaseline + DATE.brushGap * sx

  const dayFill = textBlock({
    text: input.day,
    font: roadRageFont(daySize),
    size: daySize,
    color: BRAND,
    x: startX,
    y: dayBaseline + DATE.dayOffsetY * sx,
    skewX,
    measure,
  })
  const dayShadow = textBlock({
    text: input.day,
    font: roadRageFont(daySize),
    size: daySize,
    color: CANVAS_COLORS.black,
    x: startX + DATE.shadowOffsetX * sx,
    y: dayBaseline + DATE.shadowOffsetY * sx,
    skewX,
    measure,
  })

  const monthPivot = {
    x: rightColumnX + monthWidth / 2,
    y: monthBaseline - monthHeight / 2,
  }
  const monthText = textBlock({
    text: input.month,
    font: roadRageFont(monthSize),
    size: monthSize,
    color: CANVAS_COLORS.darkText,
    x: rightColumnX + DATE.monthOffsetX * sx,
    y: monthBaseline + DATE.monthOffsetY * sx,
    rotation: (MONTH_ROTATION_DEG * Math.PI) / 180,
    skewX,
    pivot: monthPivot,
    measure,
  })

  const plateWidth = rightColumnWidth + DATE.platePadX * sx
  const plateHeight = brushHeight + DATE.platePadY * sx
  const platePivot = {
    x: rightColumnX + rightColumnWidth / 2,
    y: brushY + plateHeight / 2 - DATE.plateOffsetY * sx,
  }
  const plateRect = box(
    platePivot.x - plateWidth / 2,
    platePivot.y - plateHeight / 2,
    plateWidth,
    plateHeight,
  )
  const plateRotation = (YEAR_PLATE_ROTATION_DEG * Math.PI) / 180
  const yearText = textBlock({
    text: input.year,
    font: edoszFont(yearSize),
    size: yearSize,
    color: CANVAS_COLORS.darkText,
    align: 'center',
    x: platePivot.x,
    y: platePivot.y + yearSize * DATE.yearBaselineRatio - DATE.yearLift * sx,
    rotation: plateRotation,
    pivot: platePivot,
    measure,
  })
  const plateBounds = transformedBounds(plateRect, {
    rotation: plateRotation,
    pivot: platePivot,
  })

  return {
    canvas,
    day: { fill: dayFill, shadow: dayShadow },
    month: {
      text: monthText,
      strokeColor: BRAND,
      strokeWidth: DATE.monthStroke * sx,
    },
    yearPlate: {
      rect: plateRect,
      rotation: plateRotation,
      pivot: platePivot,
      fill: BRAND,
      year: yearText,
      bounds: plateBounds,
    },
    bounds: unionBounds([
      dayFill.bounds,
      dayShadow.bounds,
      monthText.bounds,
      plateBounds,
      yearText.bounds,
    ]),
  }
}

// ── Session standings ────────────────────────────────────────────────────────

const STANDINGS = {
  headerHeight: 90,
  contentTop: 120,
  contentGap: 50,
  cardInsetX: 90,
  innerInsetX: 150,
  cardTopPad: 38,
  metaHeight: 90,
  headerRowHeight: 36,
  cardBottomPad: 28,
  rowHeight: 68,
  rowGap: 6,
  rowRadius: 16,
  cardRadius: 32,
  rowFont: 28,
  statsFont: 24,
  headerFont: 18,
  metaFont: 20,
  titleFont: 28,
  columnGap: 28,
  nameGap: 80,
  statsGap: 120,
  recordGap: 240,
  titleGap: 44,
  bottomMargin: 38,
  storyMargin: 40,
  chevronHeight: 115,
  chevronInset: 30,
  chevronTop: 0.3,
  stripWidth: 7,
  dot: 8,
} as const

export type StandingsRow = {
  name: string
  wins: number
  losses: number
  /** pointsFor - pointsAgainst */
  diff: number
  points: number
}

export type StandingsMeta = { date: string; title: string; playerCount: number }

export type StandingsInput = {
  dimensions: ExportDimensions
  variant: Variant
  meta: StandingsMeta
  rows: readonly StandingsRow[]
  /** Zero-based page; clamped into range. */
  page?: number
  /** v1 only painted the card when a photo backed it, or on a story. */
  hasPhoto?: boolean
  /** width / height of the footer strip, when the composition draws one. */
  footerAspect?: number | null
  chevronsAspect?: number | null
  logoAspect?: number | null
  headerLabel?: string | null
  hideHeader?: boolean
  measure?: TextMeasure
}

export type StandingsRowLayout = {
  index: number
  /** Full row band, gap included. */
  band: Rect
  card: Rect
  radius: number
  strip: { rect: Rect; color: string; radius: readonly [number, number, number, number] } | null
  rank: TextBlock
  name: TextBlock
  record: TextBlock
  diff: TextBlock
  points: TextBlock
  advancing: boolean
}

export type StandingsLayout = {
  canvas: CanvasSize
  variant: Variant
  backgroundFill: string
  showsCard: boolean
  card: Rect
  cardRadius: number
  header: HeaderLayout | null
  footer: Rect | null
  chevrons: Rect | null
  meta: TextBlock
  title: TextBlock
  columnHeader: { band: Rect; labels: TextBlock[] }
  rows: StandingsRowLayout[]
  page: number
  pageCount: number
  rowsPerPage: number
  total: number
}

/**
 * v1 `drawStandingsCanvas`. v1 silently dropped everything past ten rows; here
 * the board is paginated instead, so a 20-row board never overflows the post.
 */
export function standingsLayout(input: StandingsInput): StandingsLayout {
  const measure = input.measure ?? canvasMeasureText
  const canvas = resolveCanvas(input.dimensions, input.variant)
  const { sx, sy } = frameOf(canvas)
  const width = canvas.width
  const height = canvas.height
  const story = input.variant === 'story'

  const footerHeight =
    !story && input.footerAspect != null ? width * input.footerAspect : 0
  const footer =
    footerHeight > 0 ? box(0, height - footerHeight, width, footerHeight) : null

  const cardInsetX = STANDINGS.cardInsetX * sx
  const innerInsetX = STANDINGS.innerInsetX * sx
  const cardTopPad = STANDINGS.cardTopPad * sy
  const metaHeight = STANDINGS.metaHeight * sy
  const headerRowHeight = STANDINGS.headerRowHeight * sy
  const cardBottomPad = STANDINGS.cardBottomPad * sy
  const rowHeight = STANDINGS.rowHeight * sy
  const rowGap = STANDINGS.rowGap * sy
  const fixedHeight = cardTopPad + metaHeight + headerRowHeight + cardBottomPad

  const cardTop = STANDINGS.contentTop * sy + STANDINGS.contentGap * sy
  const contentBottom = height - footerHeight - STANDINGS.bottomMargin * sy
  const available = story
    ? height - STANDINGS.storyMargin * sy * 2 - fixedHeight
    : contentBottom - cardTop - fixedHeight
  const rowsPerPage = Math.max(1, Math.floor(available / rowHeight))
  const total = input.rows.length
  const pageCount = Math.max(1, Math.ceil(total / rowsPerPage))
  const page = Math.min(Math.max(input.page ?? 0, 0), pageCount - 1)
  const rows = input.rows.slice(page * rowsPerPage, page * rowsPerPage + rowsPerPage)
  const cardHeight = fixedHeight + rows.length * rowHeight
  const cardY = story ? (height - cardHeight) / 2 : cardTop
  const card = box(cardInsetX, cardY, width - cardInsetX * 2, cardHeight)

  const innerX = innerInsetX
  const rankCenterX = innerX + STANDINGS.columnGap * sx
  const nameX = innerX + STANDINGS.nameGap * sx
  const pointsX = width - innerX
  const diffX = pointsX - STANDINGS.statsGap * sx
  const recordX = pointsX - STANDINGS.recordGap * sx

  const metaFontSize = STANDINGS.metaFont * sx
  const titleFontSize = STANDINGS.titleFont * sx
  const meta = textBlock({
    text: `${input.meta.date} \u00b7 ${input.meta.title}`,
    font: monoFont(metaFontSize),
    size: metaFontSize,
    color: CANVAS_COLORS.textDim,
    x: innerX,
    y: cardY + cardTopPad,
    measure,
  })
  const title = textBlock({
    text: `TOP ${total} OF ${input.meta.playerCount} PLAYERS`,
    font: sansFont(titleFontSize, 'bold'),
    size: titleFontSize,
    color: ACCENT,
    x: innerX,
    y: cardY + cardTopPad + STANDINGS.titleGap * sy,
    measure,
  })

  const tableTop = cardY + cardTopPad + metaHeight
  const headerFontSize = STANDINGS.headerFont * sx
  const headerFont = monoFont(headerFontSize, 'bold')
  const headerBaseline = tableTop + headerRowHeight * 0.72
  const labels = [
    textBlock({
      text: '#',
      font: headerFont,
      size: headerFontSize,
      color: BORDER,
      align: 'center',
      x: rankCenterX,
      y: headerBaseline,
      measure,
    }),
    textBlock({
      text: 'Name',
      font: headerFont,
      size: headerFontSize,
      color: BORDER,
      x: nameX,
      y: headerBaseline,
      measure,
    }),
    textBlock({
      text: 'W-L',
      font: headerFont,
      size: headerFontSize,
      color: BORDER,
      align: 'right',
      x: recordX,
      y: headerBaseline,
      measure,
    }),
    textBlock({
      text: 'Diff',
      font: headerFont,
      size: headerFontSize,
      color: BORDER,
      align: 'right',
      x: diffX,
      y: headerBaseline,
      measure,
    }),
    textBlock({
      text: 'Pts',
      font: headerFont,
      size: headerFontSize,
      color: BORDER,
      align: 'right',
      x: pointsX,
      y: headerBaseline,
      measure,
    }),
  ]

  const rowFontSize = STANDINGS.rowFont * sx
  const statsFontSize = STANDINGS.statsFont * sx
  const rowCardHeight = rowHeight - rowGap
  const rowCardWidth = width - (innerX - 10 * sx) * 2
  const rowRadius = STANDINGS.rowRadius * sx
  const stripWidth = STANDINGS.stripWidth * sx
  const rowsTop = tableTop + headerRowHeight
  const medals = ['\u{1F947}', '\u{1F948}', '\u{1F949}']

  const rowLayouts = rows.map((row, position) => {
    const index = page * rowsPerPage + position
    const band = box(
      innerX - 10 * sx,
      rowsTop + position * rowHeight,
      rowCardWidth,
      rowCardHeight,
    )
    const baseline = band.y + rowCardHeight * 0.64
    const advancing = index < 3
    const rankFont = advancing
      ? sansFont(rowFontSize)
      : sansFont(rowFontSize * 0.62, 'bold')
    const nameColor =
      index === 0
        ? ACCENT
        : index === 1
          ? CANVAS_COLORS.silver
          : index === 2
            ? CANVAS_COLORS.warning
            : TEXT
    return {
      index,
      band,
      card: box(band.x, band.y, band.width, rowCardHeight),
      radius: rowRadius,
      strip: advancing
        ? {
            rect: box(band.x, band.y, stripWidth, rowCardHeight),
            color:
              index === 0
                ? ACCENT
                : index === 1
                  ? CANVAS_COLORS.silver
                  : CANVAS_COLORS.warning,
            radius: [rowRadius, 0, 0, rowRadius] as const,
          }
        : null,
      rank: textBlock({
        text: advancing ? medals[index] : ordinal(index + 1),
        font: rankFont,
        size: advancing ? rowFontSize : rowFontSize * 0.62,
        color: advancing ? TEXT : MUTED,
        align: 'center',
        x: rankCenterX,
        y: baseline,
        measure,
      }),
      name: textBlock({
        text: row.name,
        font: sansFont(rowFontSize, 'bold'),
        size: rowFontSize,
        color: nameColor,
        x: nameX,
        y: baseline,
        maxWidth: recordX - nameX - 40 * sx,
        measure,
      }),
      record: textBlock({
        text: `${row.wins}-${row.losses}`,
        font: monoFont(statsFontSize, 'bold'),
        size: statsFontSize,
        color: CANVAS_COLORS.success,
        align: 'right',
        x: recordX,
        y: baseline,
        measure,
      }),
      diff: textBlock({
        text: row.diff > 0 ? `+${row.diff}` : String(row.diff),
        font: monoFont(statsFontSize, 'bold'),
        size: statsFontSize,
        color:
          row.diff > 0
            ? CANVAS_COLORS.success
            : row.diff < 0
              ? CANVAS_COLORS.error
              : BORDER,
        align: 'right',
        x: diffX,
        y: baseline,
        measure,
      }),
      points: textBlock({
        text: String(row.points),
        font: monoFont(statsFontSize, 'bold'),
        size: statsFontSize,
        color: CANVAS_COLORS.white,
        align: 'right',
        x: pointsX,
        y: baseline,
        measure,
      }),
      advancing,
    }
  })

  const chevrons =
    !story && input.chevronsAspect != null
      ? box(
          width -
            STANDINGS.chevronHeight * sx * input.chevronsAspect -
            STANDINGS.chevronInset * sx,
          height * STANDINGS.chevronTop,
          STANDINGS.chevronHeight * sx * input.chevronsAspect,
          STANDINGS.chevronHeight * sx,
        )
      : null

  const header =
    story || input.hideHeader
      ? null
      : headerLayout({
          canvas,
          label: input.headerLabel ?? null,
          logoAspect: input.logoAspect ?? null,
          measure,
        })

  return {
    canvas,
    variant: input.variant,
    backgroundFill: BG_DARK,
    showsCard: story || input.hasPhoto === true,
    card,
    cardRadius: STANDINGS.cardRadius * sx,
    header,
    footer,
    chevrons,
    meta,
    title,
    columnHeader: {
      band: box(innerX - 10 * sx, tableTop, rowCardWidth, headerRowHeight),
      labels,
    },
    rows: rowLayouts,
    page,
    pageCount,
    rowsPerPage,
    total,
  }
}

// ── Session match post ───────────────────────────────────────────────────────

const MATCH = {
  footerHeight: 270,
  nameRow: 80,
  nameInset: 60,
  nameMaxWidth: 360,
  scoreFont: 42,
  subtitleFont: 20,
  badgeHeight: 200,
  badgeInset: 20,
  teamLogoHeight: 250,
  teamLogoInset: 30,
  sponsorHeight: 44,
  sponsorBottom: 24,
  subtitleBottom: 76,
  subtitleGap: 14,
  scoreBottom: 44,
  chevronHeight: 115,
  chevronInset: 30,
  chevronTop: 0.18,
  chevronMirrorTop: 0.1,
} as const

export type MatchPostInput = {
  dimensions: ExportDimensions
  variant: Variant
  pairAName: string
  pairBName: string
  scoreA: number | null
  scoreB: number | null
  subtitle: string
  headerLabel?: string | null
  aspects?: {
    logo?: number | null
    chevrons?: number | null
    badge?: number | null
    sponsor?: number | null
    teamALogo?: number | null
    teamBLogo?: number | null
  }
  measure?: TextMeasure
}

export type MatchPostLayout = {
  canvas: CanvasSize
  variant: Variant
  header: HeaderLayout
  chevrons: { topRight: Rect; mirrored: RotatedRect } | null
  footer: {
    rect: Rect
    fill: string
    teamLogoA: Rect | null
    teamLogoB: Rect | null
    badge: Rect | null
    sponsor: Rect | null
  }
  names: { a: TextBlock; b: TextBlock }
  score: TextBlock
  subtitle: TextBlock
}

/** v1 `drawMatchPost`: full-bleed photo, score row in a dark footer. */
export function matchPostLayout(input: MatchPostInput): MatchPostLayout {
  const measure = input.measure ?? canvasMeasureText
  const canvas = resolveCanvas(input.dimensions, input.variant)
  const { sx } = frameOf(canvas)
  const width = canvas.width
  const height = canvas.height
  const aspects = input.aspects ?? {}

  const footerHeight = MATCH.footerHeight * sx
  const footerRect = box(0, height - footerHeight, width, footerHeight)
  const rowY = footerRect.y + MATCH.nameRow * sx
  const nameInset = MATCH.nameInset * sx
  const scoreFontSize = MATCH.scoreFont * sx
  const nameFontSize = 36 * sx

  const score = textBlock({
    text:
      input.scoreA !== null && input.scoreB !== null
        ? `${input.scoreA} \u2013 ${input.scoreB}`
        : '\u2014 vs \u2014',
    font: monoFont(scoreFontSize, 'bold'),
    size: scoreFontSize,
    color: ACCENT,
    align: 'center',
    x: width / 2,
    y: rowY,
    measure,
  })

  const nameMaxWidth = MATCH.nameMaxWidth * sx
  const names = {
    a: textBlock({
      text: input.pairAName,
      font: sansFont(nameFontSize, 'bold'),
      size: nameFontSize,
      color: CANVAS_COLORS.white,
      x: nameInset,
      y: rowY,
      maxWidth: nameMaxWidth,
      measure,
    }),
    b: textBlock({
      text: input.pairBName,
      font: sansFont(nameFontSize, 'bold'),
      size: nameFontSize,
      color: CANVAS_COLORS.white,
      align: 'right',
      x: width - nameInset,
      y: rowY,
      maxWidth: nameMaxWidth,
      measure,
    }),
  }

  const teamLogoHeight = MATCH.teamLogoHeight * sx
  const teamLogoTop = footerRect.y + (footerHeight - teamLogoHeight) / 2
  const teamLogoA =
    aspects.teamALogo != null
      ? box(
          MATCH.teamLogoInset * sx,
          teamLogoTop,
          teamLogoHeight * aspects.teamALogo,
          teamLogoHeight,
        )
      : null
  const teamLogoB =
    aspects.teamBLogo != null
      ? box(
          width - MATCH.teamLogoInset * sx - teamLogoHeight * aspects.teamBLogo,
          teamLogoTop,
          teamLogoHeight * aspects.teamBLogo,
          teamLogoHeight,
        )
      : null

  const badgeHeight = MATCH.badgeHeight * sx
  const badge =
    aspects.badge != null
      ? box(
          width - badgeHeight * aspects.badge + MATCH.badgeInset * sx,
          footerRect.y + (footerHeight - badgeHeight) / 2,
          badgeHeight * aspects.badge,
          badgeHeight,
        )
      : null

  const sponsorHeight = MATCH.sponsorHeight * sx
  const sponsor =
    aspects.sponsor != null
      ? box(
          (width - sponsorHeight * aspects.sponsor) / 2,
          footerRect.y + footerHeight - sponsorHeight - MATCH.sponsorBottom * sx,
          sponsorHeight * aspects.sponsor,
          sponsorHeight,
        )
      : null

  const subtitleFontSize = MATCH.subtitleFont * sx
  const subtitle = textBlock({
    text: input.subtitle,
    font: monoFont(subtitleFontSize),
    size: subtitleFontSize,
    color: MUTED,
    align: 'center',
    x: width / 2,
    y:
      footerRect.y +
      footerHeight -
      MATCH.scoreBottom * sx -
      MATCH.subtitleGap * sx -
      MATCH.subtitleBottom * sx,
    measure,
  })

  let chevrons: MatchPostLayout['chevrons'] = null
  if (aspects.chevrons != null) {
    const chevronWidth = MATCH.chevronHeight * sx * aspects.chevrons
    const chevronHeight = MATCH.chevronHeight * sx
    const topRight = box(
      width - chevronWidth - MATCH.chevronInset * sx,
      height * MATCH.chevronTop,
      chevronWidth,
      chevronHeight,
    )
    const mirroredRect = box(
      MATCH.chevronInset * sx,
      height * MATCH.chevronMirrorTop,
      chevronWidth,
      chevronHeight,
    )
    chevrons = {
      topRight,
      mirrored: { rect: mirroredRect, rotation: Math.PI, pivot: boxCenter(mirroredRect) },
    }
  }

  return {
    canvas,
    variant: input.variant,
    header: headerLayout({
      canvas,
      label: input.headerLabel ?? TOURNAMENT_LABEL,
      logoAspect: aspects.logo ?? null,
      measure,
    }),
    chevrons,
    footer: {
      rect: footerRect,
      fill: 'rgba(0,0,0,0.85)',
      teamLogoA,
      teamLogoB,
      badge,
      sponsor,
    },
    names,
    score,
    subtitle,
  }
}

// ── Classic bracket round cover ──────────────────────────────────────────────

const BRACKET = {
  cardInsetX: 60,
  cardPadTop: 60,
  cardPadBottom: 60,
  titleHeight: 160,
  rowHeight: 130,
  rowGap: 12,
  rowRadius: 12,
  cardRadius: 32,
  titleFont: 80,
  titleBaseline: 100,
  titleDivider: 10,
  rowInsetX: 50,
  rowInset: 16,
  rowTopPad: 4,
  rowLabelFont: 22,
  rowLabelTop: 28,
  nameFont: 38,
  scoreWidth: 160,
  scoreGap: 18,
  nameGap: 20,
  sponsorHeight: 60,
  sponsorTop: 18,
  centerShift: 60,
} as const

export type BracketRowInput = {
  label: string
  nameA: string
  nameB: string
  scoreA: number | null
  scoreB: number | null
}

export type BracketCoverInput = {
  dimensions: ExportDimensions
  variant: Variant
  roundTitle: string
  rows: readonly BracketRowInput[]
  headerLabel?: string | null
  aspects?: { logo?: number | null; sponsor?: number | null }
  hasBackground?: boolean
  measure?: TextMeasure
}

export type BracketCoverLayout = {
  canvas: CanvasSize
  variant: Variant
  backgroundFill: string
  hasBackground: boolean
  header: HeaderLayout
  card: Rect
  cardRadius: number
  sponsor: Rect | null
  title: TextBlock
  divider: { from: Point; to: Point; color: string; width: number }
  rows: {
    band: Rect
    radius: number
    label: TextBlock
    nameA: TextBlock
    score: TextBlock
    nameB: TextBlock
  }[]
}

/** v1 `drawBracketRoundCover`: one round, every pairing in a dark card. */
export function bracketCoverLayout(input: BracketCoverInput): BracketCoverLayout {
  const measure = input.measure ?? canvasMeasureText
  const canvas = resolveCanvas(input.dimensions, input.variant)
  const { sx, sy } = frameOf(canvas)
  const width = canvas.width
  const height = canvas.height
  const aspects = input.aspects ?? {}

  const cardX = BRACKET.cardInsetX * sx
  const cardWidth = width - cardX * 2
  const padTop = BRACKET.cardPadTop * sy
  const padBottom = BRACKET.cardPadBottom * sy
  const titleHeight = BRACKET.titleHeight * sy
  const rowHeight = BRACKET.rowHeight * sy
  const rowGap = BRACKET.rowGap * sy
  const count = input.rows.length
  const cardHeight =
    padTop + titleHeight + count * (rowHeight + rowGap) - (count > 0 ? rowGap : 0) + padBottom
  const cardY = (height - cardHeight) / 2 + BRACKET.centerShift * sy
  const card = box(cardX, cardY, cardWidth, cardHeight)

  const innerX = cardX + BRACKET.rowInsetX * sx
  const innerWidth = cardWidth - BRACKET.rowInsetX * sx * 2
  const scoreWidth = BRACKET.scoreWidth * sx
  const scoreCenterX = width / 2
  const nameMaxWidth = (innerWidth - scoreWidth) / 2 - BRACKET.nameGap * sx

  const titleFontSize = BRACKET.titleFont * sx
  const title = textBlock({
    text: input.roundTitle,
    font: sansFont(titleFontSize, 'bold'),
    size: titleFontSize,
    color: ACCENT,
    align: 'center',
    x: width / 2,
    y: cardY + padTop + BRACKET.titleBaseline * sy,
    letterSpacing: 3 * sx,
    measure,
  })

  const nameFontSize = BRACKET.nameFont * sx
  const scoreFontSize = BRACKET.nameFont * sx
  const labelFontSize = BRACKET.rowLabelFont * sx
  const rowsTop = cardY + padTop + titleHeight
  const rowInset = BRACKET.rowInset * sx

  const rows = input.rows.map((row, index) => {
    const bandY = rowsTop + index * (rowHeight + rowGap)
    const bandTop = bandY + BRACKET.rowTopPad * sy
    const band = box(
      cardX + rowInset,
      bandTop,
      cardWidth - rowInset * 2,
      rowHeight - BRACKET.rowTopPad * sy * 2,
    )
    const baseline = bandY + rowHeight * 0.62
    return {
      band,
      radius: BRACKET.rowRadius * sx,
      label: textBlock({
        text: row.label,
        font: monoFont(labelFontSize, 'bold'),
        size: labelFontSize,
        color: BORDER,
        x: innerX,
        y: bandY + BRACKET.rowLabelTop * sy,
        letterSpacing: 1 * sx,
        measure,
      }),
      nameA: textBlock({
        text: row.nameA,
        font: sansFont(nameFontSize, 'bold'),
        size: nameFontSize,
        color: TEXT,
        align: 'right',
        x: scoreCenterX - scoreWidth / 2 - BRACKET.scoreGap * sx,
        y: baseline,
        maxWidth: nameMaxWidth,
        measure,
      }),
      score: textBlock({
        text:
          row.scoreA !== null && row.scoreB !== null
            ? `${row.scoreA}\u2013${row.scoreB}`
            : 'vs',
        font: monoFont(scoreFontSize, 'bold'),
        size: scoreFontSize,
        color: ACCENT,
        align: 'center',
        x: scoreCenterX,
        y: baseline,
        measure,
      }),
      nameB: textBlock({
        text: row.nameB,
        font: sansFont(nameFontSize, 'bold'),
        size: nameFontSize,
        color: TEXT,
        x: scoreCenterX + scoreWidth / 2 + BRACKET.scoreGap * sx,
        y: baseline,
        maxWidth: nameMaxWidth,
        measure,
      }),
    }
  })

  const sponsorHeight = BRACKET.sponsorHeight * sx
  const sponsor =
    aspects.sponsor != null
      ? box(
          (width - sponsorHeight * aspects.sponsor) / 2,
          cardY + BRACKET.sponsorTop * sy,
          sponsorHeight * aspects.sponsor,
          sponsorHeight,
        )
      : null

  return {
    canvas,
    variant: input.variant,
    backgroundFill: CLASSIC_SURFACE,
    hasBackground: input.hasBackground === true,
    header: headerLayout({
      canvas,
      label: input.headerLabel ?? TOURNAMENT_LABEL,
      logoAspect: aspects.logo ?? null,
      measure,
    }),
    card,
    cardRadius: BRACKET.cardRadius * sx,
    sponsor,
    title,
    divider: {
      from: { x: cardX + BRACKET.rowInsetX * sx, y: rowsTop - BRACKET.titleDivider * sy },
      to: {
        x: cardX + cardWidth - BRACKET.rowInsetX * sx,
        y: rowsTop - BRACKET.titleDivider * sy,
      },
      color: DIVIDER,
      width: 1.5 * sx,
    },
    rows,
  }
}

// ── Team group summary ───────────────────────────────────────────────────────

const GROUP = {
  cardInsetX: 80,
  innerInsetX: 60,
  cardTopPad: 120,
  titleHeight: 130,
  headerHeight: 50,
  cardBottomPad: 50,
  rowHeight: 110,
  rowGap: 10,
  rowRadius: 16,
  cardRadius: 32,
  labelFont: 28,
  titleFont: 72,
  headerFont: 26,
  rankFont: 44,
  nameFont: 40,
  statsFont: 36,
  labelTop: 36,
  titleTop: 120,
  headerTop: 30,
  statsGap: 90,
  diffGap: 120,
  nameGap: 50,
  dot: 8,
  sponsorHeight: 80,
  sponsorTop: 20,
  centerShift: 80,
} as const

export type GroupRowInput = {
  name: string
  wins: number
  losses: number
  diff: number
}

export type GroupSummaryInput = {
  dimensions: ExportDimensions
  variant: Variant
  groupId: string
  rows: readonly GroupRowInput[]
  headerLabel?: string | null
  aspects?: { logo?: number | null; sponsor?: number | null }
  hasBackground?: boolean
  measure?: TextMeasure
}

export type GroupSummaryLayout = {
  canvas: CanvasSize
  variant: Variant
  backgroundFill: string
  hasBackground: boolean
  header: HeaderLayout
  card: Rect
  cardRadius: number
  sponsor: Rect | null
  caption: TextBlock
  title: TextBlock
  columnHeader: TextBlock[]
  rows: {
    band: Rect
    radius: number
    highlight: Rect | null
    rank: TextBlock
    name: TextBlock
    wins: TextBlock
    losses: TextBlock
    diff: TextBlock
    dot: { center: Point; radius: number } | null
    advancing: boolean
  }[]
}

/** v1 `drawGroupSummary`: one group table, top two marked as advancing. */
export function groupSummaryLayout(input: GroupSummaryInput): GroupSummaryLayout {
  const measure = input.measure ?? canvasMeasureText
  const canvas = resolveCanvas(input.dimensions, input.variant)
  const { sx, sy } = frameOf(canvas)
  const width = canvas.width
  const height = canvas.height
  const aspects = input.aspects ?? {}

  const cardX = GROUP.cardInsetX * sx
  const cardWidth = width - cardX * 2
  const cardTopPad = GROUP.cardTopPad * sy
  const titleHeight = GROUP.titleHeight * sy
  const headerHeight = GROUP.headerHeight * sy
  const cardBottomPad = GROUP.cardBottomPad * sy
  const rowHeight = GROUP.rowHeight * sy
  const rowGap = GROUP.rowGap * sy
  const count = input.rows.length
  const cardHeight =
    cardTopPad + titleHeight + headerHeight + count * (rowHeight + rowGap) + cardBottomPad
  const cardY = (height - cardHeight) / 2 + GROUP.centerShift * sy
  const card = box(cardX, cardY, cardWidth, cardHeight)

  const innerX = cardX + GROUP.innerInsetX * sx
  const rightX = cardX + cardWidth - GROUP.innerInsetX * sx
  const diffX = rightX - GROUP.diffGap * sx
  const lossX = diffX - GROUP.statsGap * sx
  const winX = lossX - GROUP.statsGap * sx

  const labelFontSize = GROUP.labelFont * sx
  const caption = textBlock({
    text: 'FINAL STANDINGS',
    font: monoFont(labelFontSize),
    size: labelFontSize,
    color: MUTED,
    x: innerX,
    y: cardY + cardTopPad + GROUP.labelTop * sy,
    letterSpacing: 4 * sx,
    measure,
  })

  const titleFontSize = GROUP.titleFont * sx
  const title = textBlock({
    text: `GROUP ${input.groupId}`,
    font: sansFont(titleFontSize, 'bold'),
    size: titleFontSize,
    color: ACCENT,
    x: innerX,
    y: cardY + cardTopPad + GROUP.titleTop * sy,
    letterSpacing: 2 * sx,
    measure,
  })

  const headerFontSize = GROUP.headerFont * sx
  const headerFont = monoFont(headerFontSize, 'bold')
  const headerBaseline = cardY + cardTopPad + titleHeight + GROUP.headerTop * sy
  const columnHeader = [
    textBlock({
      text: 'W',
      font: headerFont,
      size: headerFontSize,
      color: BORDER,
      align: 'center',
      x: winX,
      y: headerBaseline,
      measure,
    }),
    textBlock({
      text: 'L',
      font: headerFont,
      size: headerFontSize,
      color: BORDER,
      align: 'center',
      x: lossX,
      y: headerBaseline,
      measure,
    }),
    textBlock({
      text: '+/-',
      font: headerFont,
      size: headerFontSize,
      color: BORDER,
      align: 'right',
      x: diffX,
      y: headerBaseline,
      measure,
    }),
  ]

  const rankFontSize = GROUP.rankFont * sx
  const nameFontSize = GROUP.nameFont * sx
  const statsFontSize = GROUP.statsFont * sx
  const rowsTop = cardY + cardTopPad + titleHeight + headerHeight
  const nameX = innerX + GROUP.nameGap * sx

  const rows = input.rows.map((row, index) => {
    const bandY = rowsTop + index * (rowHeight + rowGap)
    const baseline = bandY + rowHeight * 0.65
    const advancing = index < 2
    return {
      band: box(innerX, bandY, rightX - innerX, rowHeight),
      radius: GROUP.rowRadius * sx,
      highlight: advancing
        ? box(cardX + 16 * sx, bandY, cardWidth - 32 * sx, rowHeight)
        : null,
      rank: textBlock({
        text: String(index + 1),
        font: sansFont(rankFontSize, 'bold'),
        size: rankFontSize,
        color: advancing ? ACCENT : BORDER,
        align: 'center',
        x: innerX - 10 * sx,
        y: baseline,
        measure,
      }),
      name: textBlock({
        text: row.name,
        font: sansFont(nameFontSize, 'bold'),
        size: nameFontSize,
        color: advancing ? '#fef08a' : MUTED,
        x: nameX,
        y: baseline,
        maxWidth: winX - nameX - 40 * sx,
        measure,
      }),
      wins: textBlock({
        text: String(row.wins),
        font: monoFont(statsFontSize, 'bold'),
        size: statsFontSize,
        color: advancing ? TEXT : MUTED,
        align: 'center',
        x: winX,
        y: baseline,
        measure,
      }),
      losses: textBlock({
        text: String(row.losses),
        font: monoFont(statsFontSize, 'bold'),
        size: statsFontSize,
        color: advancing ? TEXT : MUTED,
        align: 'center',
        x: lossX,
        y: baseline,
        measure,
      }),
      diff: textBlock({
        text: row.diff > 0 ? `+${row.diff}` : row.diff === 0 ? '\u2014' : String(row.diff),
        font: monoFont(statsFontSize, 'bold'),
        size: statsFontSize,
        color:
          row.diff > 0
            ? CANVAS_COLORS.success
            : row.diff < 0
              ? CANVAS_COLORS.error
              : BORDER,
        align: 'right',
        x: diffX,
        y: baseline,
        measure,
      }),
      dot: advancing
        ? { center: { x: rightX, y: bandY + rowHeight / 2 }, radius: GROUP.dot * sx }
        : null,
      advancing,
    }
  })

  const sponsorHeight = GROUP.sponsorHeight * sx
  const sponsor =
    aspects.sponsor != null
      ? box(
          (width - sponsorHeight * aspects.sponsor) / 2,
          cardY + GROUP.sponsorTop * sy,
          sponsorHeight * aspects.sponsor,
          sponsorHeight,
        )
      : null

  return {
    canvas,
    variant: input.variant,
    backgroundFill: GROUP_SURFACE,
    hasBackground: input.hasBackground === true,
    header: headerLayout({
      canvas,
      label: input.headerLabel ?? null,
      logoAspect: aspects.logo ?? null,
      measure,
    }),
    card,
    cardRadius: GROUP.cardRadius * sx,
    sponsor,
    caption,
    title,
    columnHeader,
    rows,
  }
}

// ── Team match post ──────────────────────────────────────────────────────────

const TEAM = {
  photoBottom: 940,
  photoMaxHeight: 500,
  photoInset: 30,
  photoCenterA: 0.26,
  photoCenterB: 0.74,
  innerInsetX: 100,
  partaiRowHeight: 68,
  subtitleTop: 200,
  subtitleFont: 28,
  headingTop: 295,
  headingFont: 88,
  scoreTop: 780,
  scoreLogoHeight: 175,
  scoreFont: 110,
  nameFont: 22,
  nameGap: 14,
  dividerGap: 46,
  partaiTop: 45,
  partaiTierFont: 20,
  partaiNameFont: 22,
  partaiScoreFont: 22,
  partaiNameInset: 90,
  partaiNameMaxWidth: 220,
  sponsorHeight: 44,
  sponsorBottom: 34,
  logoShadow: 12,
  blobRadius: 0.85,
  fadeHeight: 120,
} as const

export type TeamPartaiRowInput = {
  tier: string
  nameA: string
  nameB: string
  scoreA: number | null
  scoreB: number | null
}

export type TeamMatchInput = {
  dimensions: ExportDimensions
  variant: Variant
  teamAName: string
  teamBName: string
  teamAWins: number
  teamBWins: number
  partai: readonly TeamPartaiRowInput[]
  subtitle: string
  /** `"29,78,216"` style triplets, as v1 passed them. */
  teamAColor?: string
  teamBColor?: string
  headerLabel?: string | null
  aspects?: {
    logo?: number | null
    sponsor?: number | null
    teamALogo?: number | null
    teamBLogo?: number | null
    teamAPhoto?: number | null
    teamBPhoto?: number | null
    hasBackground?: boolean
  }
  measure?: TextMeasure
}

export type TeamMatchLayout = {
  canvas: CanvasSize
  variant: Variant
  base: { rect: Rect; fill: string }
  background: Rect | null
  backgroundTint: { rect: Rect; fill: string }
  colorBlobs: {
    rect: Rect
    origin: Point
    radius: number
    rgb: string
    stops: readonly (readonly [number, number])[]
  }[]
  photos: { rect: Rect; clip: Rect; grayscale: boolean; side: 'left' | 'right' }[]
  bottomFade: { rect: Rect; from: string; to: string }
  panel: { rect: Rect; fill: string }
  subtitle: TextBlock
  heading: TextBlock
  logos: { a: Rect | null; b: Rect | null; shadowA: string; shadowB: string; shadowBlur: number }
  score: TextBlock
  names: { a: TextBlock; b: TextBlock }
  divider: { from: Point; to: Point; color: string; width: number }
  partai: {
    band: Rect
    tier: TextBlock
    nameA: TextBlock
    nameB: TextBlock
    score: TextBlock
  }[]
  sponsor: Rect | null
  header: HeaderLayout
}

/**
 * v1 `drawTeamMatchPost`: two team photos over colour blobs, the team score,
 * then one row per partai.
 */
export function teamMatchLayout(input: TeamMatchInput): TeamMatchLayout {
  const measure = input.measure ?? canvasMeasureText
  const canvas = resolveCanvas(input.dimensions, input.variant)
  const { sx, sy } = frameOf(canvas)
  const width = canvas.width
  const height = canvas.height
  const aspects = input.aspects ?? {}

  const photoBottom = TEAM.photoBottom * sy
  const innerX = TEAM.innerInsetX * sx
  const rightX = width - innerX
  const partaiRowHeight = TEAM.partaiRowHeight * sy
  const colorA = input.teamAColor ?? '29,78,216'
  const colorB = input.teamBColor ?? '153,27,27'
  const stops = [
    [0, 0.65],
    [0.7, 0.2],
    [1, 0],
  ] as const

  const colorBlobs = [
    {
      rect: box(0, 0, width / 2, photoBottom),
      origin: { x: 0, y: 0 },
      radius: photoBottom * TEAM.blobRadius,
      rgb: colorA,
      stops,
    },
    {
      rect: box(width / 2, 0, width / 2, photoBottom),
      origin: { x: width, y: 0 },
      radius: photoBottom * TEAM.blobRadius,
      rgb: colorB,
      stops,
    },
  ]

  const photoHeight = TEAM.photoMaxHeight * sy
  const photoY = photoBottom - photoHeight - TEAM.photoInset * sy
  const photoClip = box(0, 0, width / 2, photoBottom)
  const aWins = input.teamAWins > input.teamBWins
  const photoFor = (
    aspect: number | null | undefined,
    side: 'left' | 'right',
    grayscale: boolean,
  ) => {
    if (aspect == null) return null
    const photoWidth = photoHeight * aspect
    const center = width * (side === 'left' ? TEAM.photoCenterA : TEAM.photoCenterB)
    return {
      rect: box(center - photoWidth / 2, photoY, photoWidth, photoHeight),
      clip:
        side === 'left'
          ? photoClip
          : box(width / 2, 0, width / 2, photoBottom),
      grayscale,
      side,
    }
  }
  const photoA = photoFor(aspects.teamAPhoto, 'left', !aWins)
  const photoB = photoFor(aspects.teamBPhoto, 'right', aWins)
  const photos = [
    ...(aWins ? [photoB, photoA] : [photoA, photoB]).filter(
      (photo): photo is NonNullable<typeof photoA> => photo !== null,
    ),
  ]

  const subtitleFontSize = TEAM.subtitleFont * sx
  const headingFontSize = TEAM.headingFont * sx
  const scoreFontSize = TEAM.scoreFont * sx
  const scoreLogoHeight = TEAM.scoreLogoHeight * sx
  const scoreTop = TEAM.scoreTop * sy
  const scoreBaseline = scoreTop + scoreLogoHeight / 2 + 36 * sx
  const nameFontSize = TEAM.nameFont * sx
  const nameBaseline = scoreTop + scoreLogoHeight + nameFontSize + TEAM.nameGap * sx
  const dividerY = nameBaseline + TEAM.dividerGap * sx
  const partaiStart = dividerY + TEAM.partaiTop * sx
  const partaiNameMaxWidth = TEAM.partaiNameMaxWidth * sx

  const partai = input.partai.map((row, index) => {
    const rowY = partaiStart + index * partaiRowHeight
    const aWon =
      row.scoreA !== null && row.scoreB !== null && row.scoreA > row.scoreB
    const bWon =
      row.scoreA !== null && row.scoreB !== null && row.scoreB > row.scoreA
    const tierFontSize = TEAM.partaiTierFont * sx
    const partaiNameFontSize = TEAM.partaiNameFont * sx
    const partaiScoreFontSize = TEAM.partaiScoreFont * sx
    return {
      band: box(innerX, rowY - partaiRowHeight / 2, rightX - innerX, partaiRowHeight),
      tier: textBlock({
        text: row.tier,
        font: monoFont(tierFontSize, 'bold'),
        size: tierFontSize,
        color: ACCENT,
        x: innerX,
        y: rowY,
        measure,
      }),
      nameA: textBlock({
        text: row.nameA,
        font: sansFont(partaiNameFontSize),
        size: partaiNameFontSize,
        color: aWon ? CANVAS_COLORS.white : CANVAS_COLORS.textDim,
        x: innerX + TEAM.partaiNameInset * sx,
        y: rowY,
        maxWidth: partaiNameMaxWidth,
        measure,
      }),
      nameB: textBlock({
        text: row.nameB,
        font: sansFont(partaiNameFontSize),
        size: partaiNameFontSize,
        color: bWon ? CANVAS_COLORS.white : CANVAS_COLORS.textDim,
        align: 'right',
        x: rightX,
        y: rowY,
        maxWidth: partaiNameMaxWidth,
        measure,
      }),
      score: textBlock({
        text:
          row.scoreA !== null && row.scoreB !== null
            ? `${row.scoreA}\u2013${row.scoreB}`
            : 'vs',
        font: monoFont(partaiScoreFontSize, 'bold'),
        size: partaiScoreFontSize,
        color: ACCENT,
        align: 'center',
        x: width / 2,
        y: rowY,
        measure,
      }),
    }
  })

  const logoA =
    aspects.teamALogo != null
      ? box(innerX, scoreTop, scoreLogoHeight * aspects.teamALogo, scoreLogoHeight)
      : null
  const logoB =
    aspects.teamBLogo != null
      ? box(
          rightX - scoreLogoHeight * aspects.teamBLogo,
          scoreTop,
          scoreLogoHeight * aspects.teamBLogo,
          scoreLogoHeight,
        )
      : null

  const scoreText = `${input.teamAWins} \u2013 ${input.teamBWins}`
  const sponsorHeight = TEAM.sponsorHeight * sx
  const sponsor =
    aspects.sponsor != null
      ? box(
          (width - sponsorHeight * aspects.sponsor) / 2,
          height - sponsorHeight - TEAM.sponsorBottom * sx,
          sponsorHeight * aspects.sponsor,
          sponsorHeight,
        )
      : null

  return {
    canvas,
    variant: input.variant,
    base: { rect: box(0, 0, width, height), fill: TEAM_BASE },
    background: aspects.hasBackground === true ? box(0, 0, width, height) : null,
    backgroundTint: { rect: box(0, 0, width, height), fill: 'rgba(2,5,18,0.05)' },
    colorBlobs,
    photos,
    bottomFade: {
      rect: box(0, photoBottom - TEAM.fadeHeight * sy, width, TEAM.fadeHeight * sy),
      from: 'rgba(3,7,15,0)',
      to: 'rgba(3,7,15,0.97)',
    },
    panel: { rect: box(0, photoBottom, width, height - photoBottom), fill: TEAM_PANEL },
    subtitle: textBlock({
      text: input.subtitle,
      font: monoFont(subtitleFontSize),
      size: subtitleFontSize,
      color: CANVAS_COLORS.textDim,
      align: 'center',
      x: width / 2,
      y: TEAM.subtitleTop * sy,
      letterSpacing: 6 * sx,
      measure,
    }),
    heading: textBlock({
      text: 'MATCH RESULT',
      font: sansFont(headingFontSize, 'bold', true),
      size: headingFontSize,
      color: ACCENT,
      align: 'center',
      x: width / 2,
      y: TEAM.headingTop * sy,
      letterSpacing: 1 * sx,
      measure,
    }),
    logos: {
      a: logoA,
      b: logoB,
      shadowA: `rgba(${colorA},0.9)`,
      shadowB: `rgba(${colorB},0.9)`,
      shadowBlur: TEAM.logoShadow * sx,
    },
    score: textBlock({
      text: scoreText,
      font: monoFont(scoreFontSize, 'bold'),
      size: scoreFontSize,
      color: ACCENT,
      align: 'center',
      x: width / 2,
      y: scoreBaseline,
      measure,
    }),
    names: {
      a: textBlock({
        text: input.teamAName,
        font: sansFont(nameFontSize, 'bold'),
        size: nameFontSize,
        color: CANVAS_COLORS.white,
        x: innerX,
        y: nameBaseline,
        maxWidth:
          width / 2 - innerX - measure(scoreText, monoFont(scoreFontSize, 'bold')) / 2 - 20 * sx,
        measure,
      }),
      b: textBlock({
        text: input.teamBName,
        font: sansFont(nameFontSize, 'bold'),
        size: nameFontSize,
        color: CANVAS_COLORS.textDim,
        align: 'right',
        x: rightX,
        y: nameBaseline,
        maxWidth:
          width / 2 - innerX - measure(scoreText, monoFont(scoreFontSize, 'bold')) / 2 - 20 * sx,
        measure,
      }),
    },
    divider: {
      from: { x: innerX, y: dividerY },
      to: { x: rightX, y: dividerY },
      color: DIVIDER,
      width: 1 * sx,
    },
    partai,
    sponsor,
    header: headerLayout({
      canvas,
      label: input.headerLabel ?? TOURNAMENT_LABEL,
      logoAspect: aspects.logo ?? null,
      measure,
    }),
  }
}
