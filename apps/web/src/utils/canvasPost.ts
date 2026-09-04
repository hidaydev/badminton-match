// src/utils/canvasPost.ts

import type { PlayerStanding } from './standings'
import type { StandingRow } from './tournament'
import { ordinal } from './ordinal'
import { HEADER_H, LOGO_H, POST_WIDTH, POST_HEIGHT, CANVAS_COLORS as C } from '../config/canvas'

/** Truncate text to fit within maxWidth, appending '…' if truncated. */
function truncateToWidth(ctx: CanvasRenderingContext2D, text: string, maxWidth: number): string {
  let truncated = text
  while (ctx.measureText(truncated + '…').width > maxWidth && truncated.length > 1) truncated = truncated.slice(0, -1)
  if (truncated !== text) truncated += '…'
  return truncated
}

/** Shared overlay image set used by multiple canvas drawing functions. */
export interface OverlayImages {
  logo?: HTMLImageElement
  footer?: HTMLImageElement
  brushStroke?: HTMLImageElement
  chevrons?: HTMLImageElement
  storyBg?: HTMLImageElement
}

export function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve(img)
    img.onerror = reject
    img.src = src
  })
}

function drawCoverFill(
  ctx: CanvasRenderingContext2D,
  img: HTMLImageElement,
  canvasW: number,
  canvasH: number,
  offsetX: number,
  offsetY: number,
  zoom: number = 1,
) {
  if (!img.naturalWidth || !img.naturalHeight) return
  const scale = Math.max(canvasW / img.naturalWidth, canvasH / img.naturalHeight) * zoom
  const w = img.naturalWidth * scale
  const h = img.naturalHeight * scale
  const x = (canvasW - w) / 2 + offsetX
  const y = (canvasH - h) / 2 + offsetY
  ctx.drawImage(img, x, y, w, h)
}

function drawSideText(
  ctx: CanvasRenderingContext2D,
  startX: number,
  y: number,
  fontSize: number,
) {
  const segments = [
    { text: 'MAJADU FUN', color: C.white },
    { text: '  •  ', color: C.accent },
    { text: 'MAJADU FUN', color: C.white },
    { text: '  •  ', color: C.accent },
    { text: 'MAJADU FUN', color: C.white },
  ]
  ctx.font = `bold ${fontSize}px Arial, sans-serif`
  ctx.letterSpacing = '1.5px'
  let x = startX
  for (const seg of segments) {
    ctx.fillStyle = seg.color
    ctx.textAlign = 'left'
    ctx.fillText(seg.text, x, y)
    x += ctx.measureText(seg.text).width
  }
}

function drawHeader(
  ctx: CanvasRenderingContext2D,
  canvasW: number,
  logo: HTMLImageElement | undefined,
  label?: string,
) {
  const grad = ctx.createLinearGradient(0, 0, 0, HEADER_H)
  grad.addColorStop(0, 'rgba(10,10,20,0.92)')
  grad.addColorStop(1, 'rgba(0,0,0,0)')
  ctx.fillStyle = grad
  ctx.fillRect(0, 0, canvasW, HEADER_H)

  const fontSize = 15
  const logoW = logo ? LOGO_H * (logo.naturalWidth / logo.naturalHeight) : 160
  const centerPad = 30
  const logoTop = (HEADER_H - LOGO_H) / 2
  const textY = HEADER_H / 2 + fontSize * 0.38

  ctx.font = `bold ${fontSize}px Arial, sans-serif`
  ctx.letterSpacing = '1.5px'

  if (label) {
    // Tournament mode: single label on both sides
    ctx.fillStyle = C.white
    ctx.textAlign = 'right'
    ctx.fillText(label, (canvasW - logoW) / 2 - centerPad, textY)
    ctx.textAlign = 'left'
    ctx.fillText(label, (canvasW + logoW) / 2 + centerPad, textY)
  } else {
    // Session mode: repeating side text
    const fullText = 'MAJADU FUN  •  MAJADU FUN  •  MAJADU FUN'
    const totalW = ctx.measureText(fullText).width
    const sideZoneW = (canvasW - logoW) / 2 - centerPad
    const clampedW = Math.min(totalW, sideZoneW)
    drawSideText(ctx, (canvasW - logoW) / 2 - centerPad - clampedW, textY, fontSize)
    drawSideText(ctx, (canvasW + logoW) / 2 + centerPad, textY, fontSize)
  }

  if (logo) {
    ctx.drawImage(logo, (canvasW - logoW) / 2, logoTop, logoW, LOGO_H)
  }
}

/** @deprecated Use `drawHeader(ctx, canvasW, logo, 'MAJADU INTERNAL TOURNAMENT 2026')` instead. */
function drawTournamentHeader(
  ctx: CanvasRenderingContext2D,
  canvasW: number,
  logo: HTMLImageElement | undefined,
) {
  drawHeader(ctx, canvasW, logo, 'MAJADU INTERNAL TOURNAMENT 2026')
}

export function drawMatchPost(
  canvas: HTMLCanvasElement,
  photo: HTMLImageElement,
  pairAName: string,
  pairBName: string,
  scoreA: number | null,
  scoreB: number | null,
  subtitle: string,
  logo: HTMLImageElement | undefined,
  badge: HTMLImageElement | undefined,
  chevrons: HTMLImageElement | undefined,
  sponsor: HTMLImageElement | undefined,
) {
  const W = POST_WIDTH
  const H = POST_HEIGHT
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, W, H)

  // Layer 1: full-bleed photo
  drawCoverFill(ctx, photo, W, H, 0, 0)

  // Chevrons
  if (chevrons) {
    const chevH = 115
    const chevW = chevH * (chevrons.naturalWidth / chevrons.naturalHeight)
    ctx.drawImage(chevrons, W - chevW - 30, H * 0.18, chevW, chevH)
    ctx.save()
    ctx.translate(30 + chevW / 2, H * 0.10 + chevH / 2)
    ctx.rotate(Math.PI)
    ctx.drawImage(chevrons, -chevW / 2, -chevH / 2, chevW, chevH)
    ctx.restore()
  }

  // Header band
  drawTournamentHeader(ctx, W, logo)

  // Footer
  const footerH = 230
  const footerY = H - footerH
  ctx.save()
  ctx.fillStyle = 'rgba(0,0,0,0.85)'
  ctx.fillRect(0, footerY, W, footerH)
  ctx.restore()

  // Sponsor logo inside footer
  if (sponsor) {
    const sH = 60
    const sW = sH * (sponsor.naturalWidth / sponsor.naturalHeight)
    ctx.drawImage(sponsor, (W - sW) / 2, footerY + 15, sW, sH)
  }

  // Names + score row
  const rowY = footerY + 140
  const maxNameW = 360
  ctx.save()
  ctx.font = 'bold 36px Arial, sans-serif'
  ctx.fillStyle = C.white
  ctx.textAlign = 'left'
  ctx.fillText(truncateToWidth(ctx, pairAName, maxNameW), 60, rowY)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 36px Arial, sans-serif'
  ctx.fillStyle = C.white
  ctx.textAlign = 'right'
  ctx.fillText(truncateToWidth(ctx, pairBName, maxNameW), W - 60, rowY)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 42px monospace'
  ctx.fillStyle = C.accent
  ctx.textAlign = 'center'
  ctx.fillText(scoreA !== null && scoreB !== null ? `${scoreA} – ${scoreB}` : '— vs —', W / 2, rowY)
  ctx.restore()

  // Badge low opacity
  if (badge) {
    const badgeH = 200
    const badgeW = badgeH * (badge.naturalWidth / badge.naturalHeight)
    ctx.save()
    ctx.globalAlpha = 0.18
    ctx.drawImage(badge, W - badgeW + 20, footerY + (footerH - badgeH) / 2, badgeW, badgeH)
    ctx.restore()
  }

  // Subtitle
  ctx.save()
  ctx.font = '20px monospace'
  ctx.fillStyle = C.muted
  ctx.textAlign = 'center'
  ctx.fillText(subtitle, W / 2, footerY + 205)
  ctx.restore()
}

export function drawBracketRoundCover(
  canvas: HTMLCanvasElement,
  roundTitle: string,
  matchRows: { label: string; nameA: string; nameB: string; scoreA: number | null; scoreB: number | null }[],
  summaryBg: HTMLImageElement | undefined,
  logo: HTMLImageElement | undefined,
  sponsor: HTMLImageElement | undefined,
) {
  const W = POST_WIDTH
  const H = POST_HEIGHT
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, W, H)

  if (summaryBg) {
    ctx.drawImage(summaryBg, 0, 0, W, H)
  } else {
    ctx.fillStyle = '#0f172a'
    ctx.fillRect(0, 0, W, H)
  }

  drawTournamentHeader(ctx, W, logo)

  const ROW_H = 130
  const ROW_GAP = 12
  const CARD_PAD_TOP = 60
  const CARD_PAD_BOT = 60
  const TITLE_H = 160
  const CARD_X = 60
  const CARD_W = W - CARD_X * 2
  const CARD_H = CARD_PAD_TOP + TITLE_H + matchRows.length * (ROW_H + ROW_GAP) - ROW_GAP + CARD_PAD_BOT
  const CARD_Y = (H - CARD_H) / 2 + 60

  ctx.save()
  ctx.fillStyle = 'rgba(4,7,14,0.85)'
  ctx.beginPath()
  ctx.roundRect(CARD_X, CARD_Y, CARD_W, CARD_H, 32)
  ctx.fill()
  ctx.restore()

  if (sponsor) {
    const sH = 60
    const sW = sH * (sponsor.naturalWidth / sponsor.naturalHeight)
    ctx.drawImage(sponsor, (W - sW) / 2, CARD_Y + 18, sW, sH)
  }

  // Round title
  ctx.save()
  ctx.font = 'bold 80px Arial, sans-serif'
  ctx.fillStyle = C.accent
  ctx.textAlign = 'center'
  ctx.letterSpacing = '3px'
  ctx.fillText(roundTitle, W / 2, CARD_Y + CARD_PAD_TOP + 100)
  ctx.restore()

  // Divider
  ctx.save()
  ctx.strokeStyle = 'rgba(250,204,21,0.25)'
  ctx.lineWidth = 1.5
  ctx.beginPath()
  ctx.moveTo(CARD_X + 60, CARD_Y + CARD_PAD_TOP + TITLE_H - 10)
  ctx.lineTo(CARD_X + CARD_W - 60, CARD_Y + CARD_PAD_TOP + TITLE_H - 10)
  ctx.stroke()
  ctx.restore()

  const INNER_X = CARD_X + 50
  const INNER_W = CARD_W - 100
  const SCORE_W = 160
  const SCORE_CX = W / 2
  const NAME_MAX_W = (INNER_W - SCORE_W) / 2 - 20

  matchRows.forEach((row, i) => {
    const rowY = CARD_Y + CARD_PAD_TOP + TITLE_H + i * (ROW_H + ROW_GAP)
    const baseline = rowY + ROW_H * 0.62

    // Row background
    ctx.save()
    ctx.fillStyle = 'rgba(255,255,255,0.03)'
    ctx.beginPath()
    ctx.roundRect(CARD_X + 16, rowY + 4, CARD_W - 32, ROW_H - 8, 12)
    ctx.fill()
    ctx.restore()

    // Match label
    ctx.save()
    ctx.font = 'bold 22px monospace'
    ctx.fillStyle = C.border
    ctx.textAlign = 'left'
    ctx.letterSpacing = '1px'
    ctx.fillText(row.label, INNER_X, rowY + 28)
    ctx.restore()

    // Team A (right-aligned to score center)
    ctx.save()
    ctx.font = 'bold 38px Arial, sans-serif'
    ctx.fillStyle = C.textPrimary
    ctx.textAlign = 'right'
    ctx.fillText(truncateToWidth(ctx, row.nameA, NAME_MAX_W), SCORE_CX - SCORE_W / 2 - 18, baseline)
    ctx.restore()

    // Score
    ctx.save()
    ctx.font = 'bold 38px monospace'
    ctx.fillStyle = C.accent
    ctx.textAlign = 'center'
    const scoreText = row.scoreA !== null && row.scoreB !== null ? `${row.scoreA}–${row.scoreB}` : 'vs'
    ctx.fillText(scoreText, SCORE_CX, baseline)
    ctx.restore()

    // Team B (left-aligned from score center)
    ctx.save()
    ctx.font = 'bold 38px Arial, sans-serif'
    ctx.fillStyle = C.textPrimary
    ctx.textAlign = 'left'
    ctx.fillText(truncateToWidth(ctx, row.nameB, NAME_MAX_W), SCORE_CX + SCORE_W / 2 + 18, baseline)
    ctx.restore()
  })
}

export function drawPositionPost(
  canvas: HTMLCanvasElement,
  photo: HTMLImageElement,
  positionLabel: string,
  name: string,
  logo: HTMLImageElement | undefined,
  chevrons: HTMLImageElement | undefined,
  sponsor: HTMLImageElement | undefined,
  badge: HTMLImageElement | undefined,
) {
  const W = POST_WIDTH
  const H = POST_HEIGHT
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, W, H)

  drawCoverFill(ctx, photo, W, H, 0, 0)

  if (chevrons) {
    const chevH = 115
    const chevW = chevH * (chevrons.naturalWidth / chevrons.naturalHeight)
    ctx.drawImage(chevrons, W - chevW - 30, H * 0.18, chevW, chevH)
    ctx.save()
    ctx.translate(30 + chevW / 2, H * 0.10 + chevH / 2)
    ctx.rotate(Math.PI)
    ctx.drawImage(chevrons, -chevW / 2, -chevH / 2, chevW, chevH)
    ctx.restore()
  }

  drawTournamentHeader(ctx, W, logo)

  // Gradient starts at 35% height, fades gently — less solid at bottom
  const gradStart = H * 0.35
  const grad = ctx.createLinearGradient(0, gradStart, 0, H)
  grad.addColorStop(0, 'rgba(0,0,0,0)')
  grad.addColorStop(0.5, 'rgba(0,0,0,0.12)')
  grad.addColorStop(0.72, 'rgba(0,0,0,0.58)')
  grad.addColorStop(0.88, 'rgba(0,0,0,0.85)')
  grad.addColorStop(1, 'rgba(0,0,0,0.94)')
  ctx.fillStyle = grad
  ctx.fillRect(0, gradStart, W, H - gradStart)

  // Big badge watermark — bottom-right, 60% visible, low opacity
  if (badge) {
    const badgeH = 680
    const badgeW = badgeH * (badge.naturalWidth / badge.naturalHeight)
    ctx.save()
    ctx.globalAlpha = 0.13
    ctx.drawImage(badge, W - badgeW * 0.64, H - badgeH * 0.64, badgeW, badgeH)
    ctx.restore()
  }

  const footerY = H - 320

  if (sponsor) {
    const sH = 60
    const sW = sH * (sponsor.naturalWidth / sponsor.naturalHeight)
    ctx.drawImage(sponsor, (W - sW) / 2, footerY + 10, sW, sH)
  }

  // Position label — bigger, tighter icon gap
  ctx.save()
  ctx.font = 'bold 56px monospace'
  ctx.fillStyle = C.accent
  ctx.textAlign = 'center'
  ctx.letterSpacing = '6px'
  ctx.fillText(positionLabel, W / 2, footerY + 140)
  ctx.restore()

  // Name — big, generous space below label
  ctx.save()
  ctx.font = 'bold 86px Arial, sans-serif'
  ctx.fillStyle = C.white
  ctx.textAlign = 'center'
  const maxW = W - 100
  ctx.fillText(truncateToWidth(ctx, name, maxW), W / 2, footerY + 240)
  ctx.restore()
}

// ── Date overlay ─────────────────────────────────────────────────────────────

function drawDate(
  ctx: CanvasRenderingContext2D,
  canvasW: number,
  day: string,
  month: string,
  year: string,
  brushStroke?: HTMLImageElement,
) {
  const daySize = 200
  const monthSize = 82
  const yearSize = 72

  ctx.font = `${daySize}px Granesta, Impact, sans-serif`
  const dayW = ctx.measureText(day).width
  ctx.font = `${monthSize}px Granesta, Impact, sans-serif`
  const monthW = ctx.measureText(month).width
  ctx.font = `${yearSize}px Edosz, Impact, sans-serif`
  const yearW = ctx.measureText(year).width

  const rightColW = Math.max(monthW, yearW + 30) + 20
  const gapX = 16
  const totalW = dayW + gapX + rightColW
  const startX = (canvasW - totalW) / 2

  const dayH = daySize * 0.88
  const monthH = monthSize * 0.88
  const brushH = yearSize + 22
  const rightColH = monthH + 14 + brushH
  const topY = 150

  const dayBaselineY = topY + Math.max(dayH, rightColH) * 0.5 + dayH * 0.5
  const rightColX = startX + dayW + gapX
  const rightColTopY = topY + (Math.max(dayH, rightColH) - rightColH) / 2
  const monthBaselineY = rightColTopY + monthH
  const brushY = monthBaselineY + 4

  // Day — black shadow + yellow fill
  ctx.save()
  ctx.font = `${daySize}px Granesta, Impact, sans-serif`
  ctx.fillStyle = C.black
  ctx.fillText(day, startX + 5, dayBaselineY + 20)
  ctx.fillStyle = C.brand
  ctx.fillText(day, startX, dayBaselineY + 15)
  ctx.restore()

  // Month — black, rotated -5deg
  ctx.save()
  ctx.font = `${monthSize}px Granesta, Impact, sans-serif`
  const mCX = rightColX + monthW / 2
  const mCY = monthBaselineY - monthH / 2
  ctx.translate(mCX, mCY)
  ctx.rotate(-5 * Math.PI / 180)
  ctx.translate(-mCX, -mCY)
  ctx.strokeStyle = C.brand
  ctx.lineWidth = 10
  ctx.lineJoin = 'round'
  ctx.strokeText(month, rightColX + 24, monthBaselineY + 30)
  ctx.fillStyle = C.darkText
  ctx.fillText(month, rightColX + 24, monthBaselineY + 30)
  ctx.restore()

  // Brush stroke background + year text
  const bW = rightColW + 160
  const bH = brushH + 110
  const bCX = rightColX + rightColW / 2
  const bCY = brushY + bH / 2 - 10
  ctx.save()
  ctx.translate(bCX, bCY)
  ctx.rotate(-6 * Math.PI / 180)
  if (brushStroke) {
    ctx.drawImage(brushStroke, -bW / 2, -bH / 2, bW, bH)
  } else {
    ctx.fillStyle = C.brand
    ctx.fillRect(-bW / 2, -bH / 2, bW, bH)
  }
  ctx.font = `${yearSize}px Edosz, Impact, sans-serif`
  ctx.fillStyle = C.darkText
  ctx.textAlign = 'center'
  ctx.fillText(year, 0, yearSize * 0.22 - 5)
  ctx.restore()
}

// ── Post canvas (photo + date + header + footer) ─────────────────────────────

interface PostCanvasOptions {
  canvas: HTMLCanvasElement
  userPhoto: HTMLImageElement | null
  photoOffset: { x: number; y: number }
  photoZoom: number
  overlays: OverlayImages
  date: { day: string; month: string; year: string } | null
}

export function drawPostCanvas(options: PostCanvasOptions) {
  const { canvas, userPhoto, photoOffset, photoZoom, overlays, date } = options
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, canvas.width, canvas.height)

  // Layer 1: user photo
  if (userPhoto) {
    drawCoverFill(ctx, userPhoto, canvas.width, canvas.height, photoOffset.x, photoOffset.y, photoZoom)
  } else {
    ctx.fillStyle = C.bgDark
    ctx.fillRect(0, 0, canvas.width, canvas.height)
  }

  // Layer 2: date + chevron ornament
  if (date) {
    drawDate(ctx, canvas.width, date.day, date.month, date.year, overlays.brushStroke)
  }
  if (overlays.chevrons) {
    const img = overlays.chevrons
    const h = 115
    const w = h * (img.naturalWidth / img.naturalHeight)
    ctx.drawImage(img, canvas.width - w - 30, canvas.height * 0.3, w, h)
  }

  // Layer 3: header band
  drawHeader(ctx, canvas.width, overlays.logo)

  // Layer 4: footer
  if (overlays.footer) {
    const img = overlays.footer
    const h = canvas.width * (img.naturalHeight / img.naturalWidth)
    ctx.drawImage(img, 0, canvas.height - h, canvas.width, h)
  }
}

// ── Standings canvas (leaderboard card) ──────────────────────────────────────

interface StandingsCanvasOptions {
  canvas: HTMLCanvasElement
  standings: PlayerStanding[]
  meta: { date: string; title: string; playerCount: number }
  overlays: Pick<OverlayImages, 'logo' | 'footer' | 'storyBg' | 'chevrons'>
  isStory: boolean
  userPhoto?: HTMLImageElement | null
  photoOffset?: { x: number; y: number }
  photoZoom?: number
}

export function drawStandingsCanvas(options: StandingsCanvasOptions) {
  const { canvas, standings, meta, overlays, isStory, userPhoto, photoOffset, photoZoom } = options
  const ctx = canvas.getContext('2d')!
  const W = canvas.width
  const H = canvas.height

  ctx.clearRect(0, 0, W, H)

  if (isStory && overlays.storyBg) {
    ctx.drawImage(overlays.storyBg, 0, 0, W, H)
  } else if (!isStory && userPhoto) {
    drawCoverFill(ctx, userPhoto, W, H, photoOffset?.x ?? 0, photoOffset?.y ?? 0, photoZoom ?? 1)
  } else {
    ctx.fillStyle = C.bgDark
    ctx.fillRect(0, 0, W, H)
  }

  if (!isStory) drawHeader(ctx, W, overlays.logo)

  const FOOTER_H = (!isStory && overlays.footer)
    ? W * (overlays.footer.naturalHeight / overlays.footer.naturalWidth)
    : 0
  if (!isStory && overlays.footer) {
    ctx.drawImage(overlays.footer, 0, H - FOOTER_H, W, FOOTER_H)
  }

  if (!isStory && overlays.chevrons) {
    const img = overlays.chevrons
    const h = 115
    const w = h * (img.naturalWidth / img.naturalHeight)
    ctx.drawImage(img, W - w - 30, H * 0.3, w, h)
  }

  const HEADER_H_PX  = 90
  const CONTENT_TOP  = HEADER_H_PX + 30
  const cardPadX     = 90
  const innerPadX    = 150

  const ROW_H        = 68
  const ROW_GAP      = 6
  const ROW_RADIUS   = 16
  const ROW_FONT     = 28
  const STATS_FONT   = 24
  const HDR_FONT     = 18
  const HEADER_ROW_H = 36
  const META_H       = 90
  const BOT_PAD      = 28

  const top10 = standings.slice(0, 10)

  const CARD_TOP_PAD = 38
  const outerCardH   = CARD_TOP_PAD + META_H + HEADER_ROW_H + top10.length * ROW_H + BOT_PAD
  const cardTop      = isStory ? Math.round((H - outerCardH) / 2) : CONTENT_TOP + 20
  if (isStory || (!isStory && userPhoto)) {
    ctx.save()
    ctx.fillStyle = 'rgba(4, 7, 14, 0.94)'
    ctx.beginPath()
    ctx.roundRect(cardPadX, cardTop, W - cardPadX * 2, outerCardH, 32)
    ctx.fill()
    ctx.restore()
  }

  const innerTop   = cardTop + CARD_TOP_PAD
  const tableTop   = innerTop + META_H

  ctx.save()
  ctx.font = '20px "IBM Plex Mono", monospace'
  ctx.fillStyle = C.textDim
  ctx.textAlign = 'left'
  ctx.fillText(`${meta.date} · ${meta.title}`, innerPadX, innerTop)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 28px "IBM Plex Sans", Arial, sans-serif'
  ctx.fillStyle = C.accent
  ctx.textAlign = 'left'
  ctx.fillText(`TOP ${top10.length} OF ${meta.playerCount} PLAYERS`, innerPadX, innerTop + 44)
  ctx.restore()

  const RANK_CX = innerPadX + 28
  const NAME_X  = innerPadX + 80
  const PTS_X   = W - innerPadX
  const DIFF_X  = W - innerPadX - 120
  const WL_X    = W - innerPadX - 240

  const MEDALS      = ['🥇', '🥈', '🥉']
  const ROW_FONT_SIZE   = ROW_FONT
  const STATS_FONT_SIZE = STATS_FONT
  const HDR_FONT_SIZE   = HDR_FONT
  const rowH            = ROW_H

  const headerY = tableTop + HEADER_ROW_H * 0.72
  ctx.save()
  ctx.fillStyle = 'rgba(255,255,255,0.04)'
  ctx.fillRect(innerPadX - 10, tableTop, W - (innerPadX - 10) * 2, HEADER_ROW_H)
  ctx.restore()

  ctx.save()
  ctx.font = `bold ${HDR_FONT_SIZE}px "IBM Plex Mono", monospace`
  ctx.fillStyle = C.border
  ctx.textAlign = 'center'; ctx.fillText('#',    RANK_CX, headerY)
  ctx.textAlign = 'left';   ctx.fillText('Name', NAME_X,  headerY)
  ctx.textAlign = 'right';  ctx.fillText('W-L',  WL_X,    headerY)
  ctx.textAlign = 'right';  ctx.fillText('Diff', DIFF_X,  headerY)
  ctx.textAlign = 'right';  ctx.fillText('Pts',  PTS_X,   headerY)
  ctx.restore()

  const rowsTop = tableTop + HEADER_ROW_H

  for (let i = 0; i < top10.length; i++) {
    const standing = top10[i]
    const rowY = rowsTop + i * rowH
    const cardH = rowH - ROW_GAP
    const baseline = rowY + cardH * 0.64

    const cardBg = i < 3
      ? 'rgba(250, 204, 21, 0.14)'
      : 'rgba(255, 255, 255, 0.04)'
    ctx.save()
    ctx.fillStyle = cardBg
    ctx.beginPath()
    ctx.roundRect(innerPadX - 10, rowY, W - (innerPadX - 10) * 2, cardH, ROW_RADIUS)
    ctx.fill()
    ctx.restore()

    if (i < 3) {
      const accentColor = i === 0 ? C.accent : i === 1 ? C.silver : C.warning
      ctx.save()
      ctx.fillStyle = accentColor
      ctx.beginPath()
      ctx.roundRect(innerPadX - 10, rowY, 7, cardH, [ROW_RADIUS, 0, 0, ROW_RADIUS])
      ctx.fill()
      ctx.restore()
    }

    ctx.save()
    if (i < 3) {
      ctx.font = `${ROW_FONT_SIZE}px "IBM Plex Sans", Arial`
      ctx.textAlign = 'center'
      ctx.fillText(MEDALS[i], RANK_CX, baseline)
    } else {
      ctx.font = `bold ${ROW_FONT_SIZE * 0.62}px "IBM Plex Sans", Arial, sans-serif`
      ctx.fillStyle = C.muted
      ctx.textAlign = 'center'
      ctx.fillText(ordinal(i + 1), RANK_CX, baseline)
    }
    ctx.restore()

    ctx.save()
    ctx.font = `bold ${ROW_FONT_SIZE}px "IBM Plex Sans", Arial, sans-serif`
    ctx.fillStyle = i === 0 ? C.accent : i === 1 ? C.silver : i === 2 ? C.warning : C.textPrimary
    ctx.textAlign = 'left'
    const maxNameW = WL_X - NAME_X - 40
    ctx.fillText(truncateToWidth(ctx, standing.player.name, maxNameW), NAME_X, baseline)
    ctx.restore()

    ctx.save()
    ctx.font = `bold ${STATS_FONT_SIZE}px "IBM Plex Mono", monospace`
    ctx.fillStyle = C.success
    ctx.textAlign = 'right'
    ctx.fillText(`${standing.wins}-${standing.losses}`, WL_X, baseline)
    ctx.restore()

    const diff = standing.diff
    ctx.save()
    ctx.font = `bold ${STATS_FONT_SIZE}px "IBM Plex Mono", monospace`
    ctx.fillStyle = diff > 0 ? C.success : diff < 0 ? C.error : C.border
    ctx.textAlign = 'right'
    ctx.fillText(diff > 0 ? `+${diff}` : String(diff), DIFF_X, baseline)
    ctx.restore()

    ctx.save()
    ctx.font = `bold ${STATS_FONT_SIZE}px "IBM Plex Mono", monospace`
    ctx.fillStyle = C.white
    ctx.textAlign = 'right'
    ctx.fillText(String(standing.pointsFor), PTS_X, baseline)
    ctx.restore()
  }
}

// ── Group standings canvas ───────────────────────────────────────────────────

export function drawGroupSummary(
  canvas: HTMLCanvasElement,
  groupId: string,
  standings: StandingRow[],
  getPairName: (id: string | null) => string,
  summaryBg: HTMLImageElement | undefined,
  sponsor: HTMLImageElement | undefined,
  logo: HTMLImageElement | undefined,
) {
  const W = POST_WIDTH
  const H = POST_HEIGHT
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, W, H)

  if (summaryBg) {
    ctx.drawImage(summaryBg, 0, 0, W, H)
  } else {
    ctx.fillStyle = '#f59e0b'
    ctx.fillRect(0, 0, W, H)
  }

  drawHeader(ctx, W, logo)

  const CARD_X = 80
  const CARD_W = W - CARD_X * 2
  const ROW_H = 110
  const ROW_GAP = 10
  const CARD_PAD_TOP = 120
  const TITLE_H = 130
  const HDR_H = 50
  const CARD_PAD_BOT = 50
  const CARD_H = CARD_PAD_TOP + TITLE_H + HDR_H + standings.length * (ROW_H + ROW_GAP) + CARD_PAD_BOT
  const CARD_Y = (H - CARD_H) / 2 + 80

  ctx.save()
  ctx.fillStyle = 'rgba(4,7,14,0.82)'
  ctx.beginPath()
  ctx.roundRect(CARD_X, CARD_Y, CARD_W, CARD_H, 32)
  ctx.fill()
  ctx.restore()

  if (sponsor) {
    const sH = 80
    const sW = sH * (sponsor.naturalWidth / sponsor.naturalHeight)
    ctx.drawImage(sponsor, (W - sW) / 2, CARD_Y + 20, sW, sH)
  }

  const INNER_X = CARD_X + 60
  ctx.save()
  ctx.font = '28px monospace'
  ctx.fillStyle = C.muted
  ctx.letterSpacing = '4px'
  ctx.textAlign = 'left'
  ctx.fillText('FINAL STANDINGS', INNER_X, CARD_Y + CARD_PAD_TOP + 36)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 72px Arial, sans-serif'
  ctx.fillStyle = C.accent
  ctx.letterSpacing = '2px'
  ctx.textAlign = 'left'
  ctx.fillText(`GROUP ${groupId}`, INNER_X, CARD_Y + CARD_PAD_TOP + 120)
  ctx.restore()

  const HDR_Y = CARD_Y + CARD_PAD_TOP + TITLE_H + 30
  const RIGHT_X = CARD_X + CARD_W - 60
  const DIFF_X = RIGHT_X - 120
  const L_X = DIFF_X - 90
  const W_X = L_X - 90
  const DOT_X = RIGHT_X

  ctx.save()
  ctx.font = 'bold 26px monospace'
  ctx.fillStyle = C.border
  ctx.textAlign = 'center'; ctx.fillText('W', W_X, HDR_Y)
  ctx.textAlign = 'center'; ctx.fillText('L', L_X, HDR_Y)
  ctx.textAlign = 'right';  ctx.fillText('+/-', DIFF_X, HDR_Y)
  ctx.restore()

  const ROWS_Y = CARD_Y + CARD_PAD_TOP + TITLE_H + HDR_H

  standings.forEach((row, i) => {
    const rowY = ROWS_Y + i * (ROW_H + ROW_GAP)
    const baseline = rowY + ROW_H * 0.65
    const isAdvancing = i < 2

    if (isAdvancing) {
      ctx.save()
      ctx.fillStyle = 'rgba(250,204,21,0.07)'
      ctx.beginPath()
      ctx.roundRect(CARD_X + 16, rowY, CARD_W - 32, ROW_H, 16)
      ctx.fill()
      ctx.restore()
    }

    ctx.save()
    ctx.font = 'bold 44px Arial, sans-serif'
    ctx.fillStyle = isAdvancing ? C.accent : C.border
    ctx.textAlign = 'center'
    ctx.fillText(String(i + 1), INNER_X - 10, baseline)
    ctx.restore()

    ctx.save()
    ctx.font = 'bold 40px Arial, sans-serif'
    ctx.fillStyle = isAdvancing ? '#fef08a' : C.muted
    ctx.textAlign = 'left'
    const nameX = INNER_X + 50
    const maxW = W_X - nameX - 40
    ctx.fillText(truncateToWidth(ctx, getPairName(row.pairId), maxW), nameX, baseline)
    ctx.restore()

    ctx.save()
    ctx.font = 'bold 36px monospace'
    ctx.fillStyle = isAdvancing ? C.textPrimary : C.muted
    ctx.textAlign = 'center'
    ctx.fillText(String(row.wins), W_X, baseline)
    ctx.restore()

    ctx.save()
    ctx.font = 'bold 36px monospace'
    ctx.fillStyle = isAdvancing ? C.textPrimary : C.muted
    ctx.textAlign = 'center'
    ctx.fillText(String(row.losses), L_X, baseline)
    ctx.restore()

    ctx.save()
    ctx.font = 'bold 36px monospace'
    ctx.fillStyle = row.diff > 0 ? C.success : row.diff < 0 ? C.error : C.border
    ctx.textAlign = 'right'
    ctx.fillText(row.diff > 0 ? `+${row.diff}` : row.diff === 0 ? '—' : String(row.diff), DIFF_X, baseline)
    ctx.restore()

    if (isAdvancing) {
      ctx.save()
      ctx.fillStyle = C.accent
      ctx.beginPath()
      ctx.arc(DOT_X, rowY + ROW_H / 2, 8, 0, Math.PI * 2)
      ctx.fill()
      ctx.restore()
    }
  })
}
