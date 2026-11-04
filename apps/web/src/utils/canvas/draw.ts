// Painting for the social exports.
//
// Every number here comes from a layout produced by `layout.ts`: no position,
// font size or box is computed while drawing. That keeps a layout assertion a
// rendering assertion, and it is why these functions are short.

import type { Point, Rect } from './geometry'
import { box } from './geometry'
import {
  ACCENT,
  CARD_FILL,
  HEADER_ROW_FILL,
  ROW_ADVANCING,
  ROW_BASE,
  ROW_HIGHLIGHT,
} from './palette'
import { drawCoverFill, drawCoverImage, drawImageIn } from './images'
import type {
  BracketCoverInput,
  BracketCoverLayout,
  DateOverlayLayout,
  GroupSummaryInput,
  GroupSummaryLayout,
  HeaderLayout,
  MatchPostInput,
  MatchPostLayout,
  StandingsInput,
  StandingsLayout,
  TeamMatchInput,
  TeamMatchLayout,
} from './layout'
import {
  bracketCoverLayout,
  groupSummaryLayout,
  matchPostLayout,
  standingsLayout,
  teamMatchLayout,
} from './layout'
import type { TextBlock } from './text'

type Corners = readonly [number, number, number, number]

type SpacedContext = CanvasRenderingContext2D & { letterSpacing: string }

function setLetterSpacing(ctx: CanvasRenderingContext2D, value: number): void {
  if (value === 0) return
  ;(ctx as SpacedContext).letterSpacing = `${value}px`
}

function applyTransform(
  ctx: CanvasRenderingContext2D,
  rotation: number,
  skewX: number,
  pivot: Point,
): void {
  if (rotation === 0 && skewX === 0) return
  ctx.translate(pivot.x, pivot.y)
  if (rotation !== 0) ctx.rotate(rotation)
  if (skewX !== 0) ctx.transform(1, 0, Math.tan(skewX), 1, 0, 0)
  ctx.translate(-pivot.x, -pivot.y)
}

/** Draw one text block exactly where the layout put it. */
export function paintText(
  ctx: CanvasRenderingContext2D,
  block: TextBlock,
  stroke?: { color: string; width: number },
): void {
  if (block.text === '') return
  ctx.save()
  ctx.font = block.font
  ctx.textAlign = block.align
  ctx.textBaseline = 'alphabetic'
  setLetterSpacing(ctx, block.letterSpacing)
  applyTransform(ctx, block.rotation, block.skewX, block.pivot)
  if (stroke !== undefined) {
    ctx.strokeStyle = stroke.color
    ctx.lineWidth = stroke.width
    ctx.lineJoin = 'round'
    ctx.strokeText(block.text, block.x, block.y)
  }
  ctx.fillStyle = block.color
  ctx.fillText(block.text, block.x, block.y)
  ctx.restore()
}

function roundedPath(
  ctx: CanvasRenderingContext2D,
  rect: Rect,
  radius: number | Corners,
): void {
  ctx.beginPath()
  if (typeof radius === 'number') {
    ctx.roundRect(rect.x, rect.y, rect.width, rect.height, radius)
  } else {
    ctx.roundRect(rect.x, rect.y, rect.width, rect.height, [...radius])
  }
}

function fillRounded(
  ctx: CanvasRenderingContext2D,
  rect: Rect,
  radius: number | Corners,
  fill: string,
): void {
  ctx.save()
  ctx.fillStyle = fill
  roundedPath(ctx, rect, radius)
  ctx.fill()
  ctx.restore()
}

function fillRect(ctx: CanvasRenderingContext2D, rect: Rect, fill: string): void {
  ctx.save()
  ctx.fillStyle = fill
  ctx.fillRect(rect.x, rect.y, rect.width, rect.height)
  ctx.restore()
}

function strokeLine(
  ctx: CanvasRenderingContext2D,
  from: Point,
  to: Point,
  color: string,
  width: number,
): void {
  ctx.save()
  ctx.strokeStyle = color
  ctx.lineWidth = width
  ctx.beginPath()
  ctx.moveTo(from.x, from.y)
  ctx.lineTo(to.x, to.y)
  ctx.stroke()
  ctx.restore()
}

function fillCircle(
  ctx: CanvasRenderingContext2D,
  center: Point,
  radius: number,
  fill: string,
): void {
  ctx.save()
  ctx.fillStyle = fill
  ctx.beginPath()
  ctx.arc(center.x, center.y, radius, 0, Math.PI * 2)
  ctx.fill()
  ctx.restore()
}

// ── Header ───────────────────────────────────────────────────────────────────

/** v1 `drawHeader`: gradient band, centred logo, mirrored side text. */
export function drawHeader(
  ctx: CanvasRenderingContext2D,
  layout: HeaderLayout,
  logo?: HTMLImageElement | null,
): void {
  const gradient = ctx.createLinearGradient(
    0,
    layout.rect.y,
    0,
    layout.rect.y + layout.rect.height,
  )
  gradient.addColorStop(0, layout.gradient.from)
  gradient.addColorStop(1, layout.gradient.to)
  ctx.save()
  ctx.fillStyle = gradient
  ctx.fillRect(layout.rect.x, layout.rect.y, layout.rect.width, layout.rect.height)
  ctx.restore()

  for (const text of layout.texts) paintText(ctx, text)
  if (layout.logo !== null && logo != null) drawImageIn(ctx, logo, layout.logo)
}

// ── Date overlay ─────────────────────────────────────────────────────────────

/**
 * v1 `drawDate`. The day and the month run through the same Road Rage skew the
 * layout records; the year sits on the brush-stroke plate.
 */
export function drawDate(
  ctx: CanvasRenderingContext2D,
  layout: DateOverlayLayout,
  brushStroke?: HTMLImageElement | null,
): void {
  paintText(ctx, layout.day.shadow)
  paintText(ctx, layout.day.fill)
  paintText(ctx, layout.month.text, {
    color: layout.month.strokeColor,
    width: layout.month.strokeWidth,
  })

  const plate = layout.yearPlate
  ctx.save()
  applyTransform(ctx, plate.rotation, 0, plate.pivot)
  if (brushStroke != null && brushStroke.naturalWidth > 0) {
    ctx.drawImage(
      brushStroke,
      plate.rect.x,
      plate.rect.y,
      plate.rect.width,
      plate.rect.height,
    )
  } else {
    ctx.fillStyle = plate.fill
    ctx.fillRect(plate.rect.x, plate.rect.y, plate.rect.width, plate.rect.height)
  }
  ctx.restore()
  paintText(ctx, plate.year)
}

// ── Session standings ────────────────────────────────────────────────────────

export type PhotoCrop = { offsetX?: number; offsetY?: number; zoom?: number }

export type StandingsImages = {
  photo?: HTMLImageElement | null
  storyBackground?: HTMLImageElement | null
  logo?: HTMLImageElement | null
  footer?: HTMLImageElement | null
  chevrons?: HTMLImageElement | null
}

export function drawStandings(
  ctx: CanvasRenderingContext2D,
  layout: StandingsLayout,
  images: StandingsImages = {},
  crop: PhotoCrop = {},
): void {
  const { width, height } = layout.canvas
  ctx.clearRect(0, 0, width, height)

  if (layout.variant === 'story' && images.storyBackground != null) {
    drawCoverImage(ctx, images.storyBackground, width, height)
  } else if (images.photo != null) {
    drawCoverFill(
      ctx,
      images.photo,
      width,
      height,
      crop.offsetX ?? 0,
      crop.offsetY ?? 0,
      crop.zoom ?? 1,
    )
  } else {
    fillRect(ctx, box(0, 0, width, height), layout.backgroundFill)
  }

  if (layout.header !== null) drawHeader(ctx, layout.header, images.logo)
  if (layout.footer !== null && images.footer != null) {
    drawImageIn(ctx, images.footer, layout.footer)
  }
  if (layout.chevrons !== null && images.chevrons != null) {
    drawImageIn(ctx, images.chevrons, layout.chevrons)
  }
  if (layout.showsCard) fillRounded(ctx, layout.card, layout.cardRadius, CARD_FILL)

  paintText(ctx, layout.meta)
  paintText(ctx, layout.title)
  fillRect(ctx, layout.columnHeader.band, HEADER_ROW_FILL)
  for (const label of layout.columnHeader.labels) paintText(ctx, label)

  for (const row of layout.rows) {
    fillRounded(
      ctx,
      row.card,
      row.radius,
      row.advancing ? ROW_HIGHLIGHT : ROW_BASE,
    )
    if (row.strip !== null) {
      fillRounded(ctx, row.strip.rect, row.strip.radius, row.strip.color)
    }
    paintText(ctx, row.rank)
    paintText(ctx, row.name)
    paintText(ctx, row.record)
    paintText(ctx, row.diff)
    paintText(ctx, row.points)
  }
}

// ── Session match post ───────────────────────────────────────────────────────

export type MatchPostImages = {
  photo?: HTMLImageElement | null
  logo?: HTMLImageElement | null
  chevrons?: HTMLImageElement | null
  badge?: HTMLImageElement | null
  sponsor?: HTMLImageElement | null
  teamALogo?: HTMLImageElement | null
  teamBLogo?: HTMLImageElement | null
}

/** v1 `drawMatchPost`: full-bleed photo, header band, dark footer with score. */
export function drawMatchPost(
  ctx: CanvasRenderingContext2D,
  layout: MatchPostLayout,
  images: MatchPostImages = {},
  crop: PhotoCrop = {},
): void {
  const { width, height } = layout.canvas
  ctx.clearRect(0, 0, width, height)
  if (images.photo != null) {
    drawCoverFill(
      ctx,
      images.photo,
      width,
      height,
      crop.offsetX ?? 0,
      crop.offsetY ?? 0,
      crop.zoom ?? 1,
    )
  }

  if (layout.chevrons !== null && images.chevrons != null) {
    drawImageIn(ctx, images.chevrons, layout.chevrons.topRight)
    ctx.save()
    applyTransform(
      ctx,
      layout.chevrons.mirrored.rotation,
      0,
      layout.chevrons.mirrored.pivot,
    )
    drawImageIn(ctx, images.chevrons, layout.chevrons.mirrored.rect)
    ctx.restore()
  }

  drawHeader(ctx, layout.header, images.logo)
  fillRect(ctx, layout.footer.rect, layout.footer.fill)

  if (layout.footer.teamLogoA !== null && images.teamALogo != null) {
    ctx.save()
    ctx.globalAlpha = 0.25
    drawImageIn(ctx, images.teamALogo, layout.footer.teamLogoA)
    ctx.restore()
  }
  if (layout.footer.teamLogoB !== null && images.teamBLogo != null) {
    ctx.save()
    ctx.globalAlpha = 0.25
    drawImageIn(ctx, images.teamBLogo, layout.footer.teamLogoB)
    ctx.restore()
  }
  if (layout.footer.sponsor !== null && images.sponsor != null) {
    drawImageIn(ctx, images.sponsor, layout.footer.sponsor)
  }

  paintText(ctx, layout.names.a)
  paintText(ctx, layout.names.b)
  paintText(ctx, layout.score)

  if (layout.footer.badge !== null && images.badge != null) {
    ctx.save()
    ctx.globalAlpha = 0.18
    drawImageIn(ctx, images.badge, layout.footer.badge)
    ctx.restore()
  }
  paintText(ctx, layout.subtitle)
}

// ── Classic bracket round cover ──────────────────────────────────────────────

export type BracketCoverImages = {
  background?: HTMLImageElement | null
  logo?: HTMLImageElement | null
  sponsor?: HTMLImageElement | null
}

export function drawBracketCover(
  ctx: CanvasRenderingContext2D,
  layout: BracketCoverLayout,
  images: BracketCoverImages = {},
): void {
  const { width, height } = layout.canvas
  ctx.clearRect(0, 0, width, height)

  if (layout.hasBackground && images.background != null) {
    drawCoverImage(ctx, images.background, width, height)
  } else {
    fillRect(ctx, box(0, 0, width, height), layout.backgroundFill)
  }

  drawHeader(ctx, layout.header, images.logo)
  fillRounded(ctx, layout.card, layout.cardRadius, 'rgba(4,7,14,0.85)')
  if (layout.sponsor !== null && images.sponsor != null) {
    drawImageIn(ctx, images.sponsor, layout.sponsor)
  }
  paintText(ctx, layout.title)
  strokeLine(
    ctx,
    layout.divider.from,
    layout.divider.to,
    layout.divider.color,
    layout.divider.width,
  )

  for (const row of layout.rows) {
    fillRounded(ctx, row.band, row.radius, 'rgba(255,255,255,0.03)')
    paintText(ctx, row.label)
    paintText(ctx, row.nameA)
    paintText(ctx, row.score)
    paintText(ctx, row.nameB)
  }
}

// ── Team group summary ───────────────────────────────────────────────────────

export type GroupSummaryImages = {
  background?: HTMLImageElement | null
  logo?: HTMLImageElement | null
  sponsor?: HTMLImageElement | null
}

export function drawGroupSummary(
  ctx: CanvasRenderingContext2D,
  layout: GroupSummaryLayout,
  images: GroupSummaryImages = {},
): void {
  const { width, height } = layout.canvas
  ctx.clearRect(0, 0, width, height)

  if (layout.hasBackground && images.background != null) {
    drawCoverImage(ctx, images.background, width, height)
  } else {
    fillRect(ctx, box(0, 0, width, height), layout.backgroundFill)
  }

  drawHeader(ctx, layout.header, images.logo)
  fillRounded(ctx, layout.card, layout.cardRadius, 'rgba(4,7,14,0.82)')
  if (layout.sponsor !== null && images.sponsor != null) {
    drawImageIn(ctx, images.sponsor, layout.sponsor)
  }
  paintText(ctx, layout.caption)
  paintText(ctx, layout.title)
  for (const label of layout.columnHeader) paintText(ctx, label)

  for (const row of layout.rows) {
    if (row.highlight !== null) {
      fillRounded(ctx, row.highlight, row.radius, ROW_ADVANCING)
    }
    paintText(ctx, row.rank)
    paintText(ctx, row.name)
    paintText(ctx, row.wins)
    paintText(ctx, row.losses)
    paintText(ctx, row.diff)
    if (row.dot !== null) fillCircle(ctx, row.dot.center, row.dot.radius, ACCENT)
  }
}

// ── Team match post ──────────────────────────────────────────────────────────

export type TeamMatchImages = {
  background?: HTMLImageElement | null
  logo?: HTMLImageElement | null
  sponsor?: HTMLImageElement | null
  teamALogo?: HTMLImageElement | null
  teamBLogo?: HTMLImageElement | null
  teamAPhoto?: HTMLImageElement | null
  teamBPhoto?: HTMLImageElement | null
}

/** v1 `drawTeamMatchPost`: photos over colour blobs, team score, partai rows. */
export function drawTeamMatch(
  ctx: CanvasRenderingContext2D,
  layout: TeamMatchLayout,
  images: TeamMatchImages = {},
): void {
  const { width, height } = layout.canvas
  ctx.clearRect(0, 0, width, height)
  fillRect(ctx, layout.base.rect, layout.base.fill)

  if (layout.background !== null && images.background != null) {
    ctx.save()
    ctx.globalAlpha = 0.9
    drawCoverFill(ctx, images.background, width, height)
    ctx.restore()
  }
  fillRect(ctx, layout.backgroundTint.rect, layout.backgroundTint.fill)

  for (const blob of layout.colorBlobs) {
    const gradient = ctx.createRadialGradient(
      blob.origin.x,
      blob.origin.y,
      0,
      blob.origin.x,
      blob.origin.y,
      blob.radius,
    )
    for (const [stop, alpha] of blob.stops) {
      gradient.addColorStop(stop, `rgba(${blob.rgb},${alpha})`)
    }
    ctx.save()
    ctx.fillStyle = gradient
    ctx.fillRect(blob.rect.x, blob.rect.y, blob.rect.width, blob.rect.height)
    ctx.restore()
  }

  for (const photo of layout.photos) {
    const image = photo.side === 'left' ? images.teamAPhoto : images.teamBPhoto
    if (image == null) continue
    ctx.save()
    ctx.beginPath()
    ctx.rect(photo.clip.x, photo.clip.y, photo.clip.width, photo.clip.height)
    ctx.clip()
    if (photo.grayscale) ctx.filter = 'grayscale(0.9) brightness(0.85)'
    ctx.drawImage(image, photo.rect.x, photo.rect.y, photo.rect.width, photo.rect.height)
    ctx.filter = 'none'
    ctx.restore()
  }

  const fade = ctx.createLinearGradient(
    0,
    layout.bottomFade.rect.y,
    0,
    layout.bottomFade.rect.y + layout.bottomFade.rect.height,
  )
  fade.addColorStop(0, layout.bottomFade.from)
  fade.addColorStop(1, layout.bottomFade.to)
  ctx.save()
  ctx.fillStyle = fade
  ctx.fillRect(
    layout.bottomFade.rect.x,
    layout.bottomFade.rect.y,
    layout.bottomFade.rect.width,
    layout.bottomFade.rect.height,
  )
  ctx.restore()
  fillRect(ctx, layout.panel.rect, layout.panel.fill)

  paintText(ctx, layout.subtitle)
  paintText(ctx, layout.heading)

  if (layout.logos.a !== null && images.teamALogo != null) {
    ctx.save()
    ctx.shadowColor = layout.logos.shadowA
    ctx.shadowBlur = layout.logos.shadowBlur
    drawImageIn(ctx, images.teamALogo, layout.logos.a)
    ctx.restore()
  }
  if (layout.logos.b !== null && images.teamBLogo != null) {
    ctx.save()
    ctx.shadowColor = layout.logos.shadowB
    ctx.shadowBlur = layout.logos.shadowBlur
    drawImageIn(ctx, images.teamBLogo, layout.logos.b)
    ctx.restore()
  }

  paintText(ctx, layout.score)
  paintText(ctx, layout.names.a)
  paintText(ctx, layout.names.b)
  strokeLine(
    ctx,
    layout.divider.from,
    layout.divider.to,
    layout.divider.color,
    layout.divider.width,
  )

  for (const row of layout.partai) {
    paintText(ctx, row.tier)
    paintText(ctx, row.nameA)
    paintText(ctx, row.score)
    paintText(ctx, row.nameB)
  }

  if (layout.sponsor !== null && images.sponsor != null) {
    drawImageIn(ctx, images.sponsor, layout.sponsor)
  }
  drawHeader(ctx, layout.header, images.logo)
}

// ── Entry points ─────────────────────────────────────────────────────────────

export type StandingsPostInput = Omit<StandingsInput, 'variant'>
export type MatchPostCanvasInput = Omit<MatchPostInput, 'variant'>
export type BracketCoverCanvasInput = Omit<BracketCoverInput, 'variant'>
export type GroupSummaryCanvasInput = Omit<GroupSummaryInput, 'variant'>
export type TeamMatchCanvasInput = Omit<TeamMatchInput, 'variant'>

/** Solve the layout, paint it, and hand the layout back for inspection. */
export function renderStandingsPost(
  ctx: CanvasRenderingContext2D,
  input: StandingsPostInput,
  images: StandingsImages = {},
  crop: PhotoCrop = {},
): StandingsLayout {
  const layout = standingsLayout({ ...input, variant: 'post' })
  drawStandings(ctx, layout, images, crop)
  return layout
}

export function renderStandingsStory(
  ctx: CanvasRenderingContext2D,
  input: StandingsPostInput,
  images: StandingsImages = {},
  crop: PhotoCrop = {},
): StandingsLayout {
  const layout = standingsLayout({ ...input, variant: 'story' })
  drawStandings(ctx, layout, images, crop)
  return layout
}

export function renderMatchPost(
  ctx: CanvasRenderingContext2D,
  input: MatchPostCanvasInput,
  images: MatchPostImages = {},
  crop: PhotoCrop = {},
): MatchPostLayout {
  const layout = matchPostLayout({ ...input, variant: 'post' })
  drawMatchPost(ctx, layout, images, crop)
  return layout
}

export function renderMatchStory(
  ctx: CanvasRenderingContext2D,
  input: MatchPostCanvasInput,
  images: MatchPostImages = {},
  crop: PhotoCrop = {},
): MatchPostLayout {
  const layout = matchPostLayout({ ...input, variant: 'story' })
  drawMatchPost(ctx, layout, images, crop)
  return layout
}

export function renderBracketCoverPost(
  ctx: CanvasRenderingContext2D,
  input: BracketCoverCanvasInput,
  images: BracketCoverImages = {},
): BracketCoverLayout {
  const layout = bracketCoverLayout({ ...input, variant: 'post' })
  drawBracketCover(ctx, layout, images)
  return layout
}

export function renderBracketCoverStory(
  ctx: CanvasRenderingContext2D,
  input: BracketCoverCanvasInput,
  images: BracketCoverImages = {},
): BracketCoverLayout {
  const layout = bracketCoverLayout({ ...input, variant: 'story' })
  drawBracketCover(ctx, layout, images)
  return layout
}

export function renderGroupSummaryPost(
  ctx: CanvasRenderingContext2D,
  input: GroupSummaryCanvasInput,
  images: GroupSummaryImages = {},
): GroupSummaryLayout {
  const layout = groupSummaryLayout({ ...input, variant: 'post' })
  drawGroupSummary(ctx, layout, images)
  return layout
}

export function renderGroupSummaryStory(
  ctx: CanvasRenderingContext2D,
  input: GroupSummaryCanvasInput,
  images: GroupSummaryImages = {},
): GroupSummaryLayout {
  const layout = groupSummaryLayout({ ...input, variant: 'story' })
  drawGroupSummary(ctx, layout, images)
  return layout
}

export function renderTeamMatchPost(
  ctx: CanvasRenderingContext2D,
  input: TeamMatchCanvasInput,
  images: TeamMatchImages = {},
): TeamMatchLayout {
  const layout = teamMatchLayout({ ...input, variant: 'post' })
  drawTeamMatch(ctx, layout, images)
  return layout
}

export function renderTeamMatchStory(
  ctx: CanvasRenderingContext2D,
  input: TeamMatchCanvasInput,
  images: TeamMatchImages = {},
): TeamMatchLayout {
  const layout = teamMatchLayout({ ...input, variant: 'story' })
  drawTeamMatch(ctx, layout, images)
  return layout
}
