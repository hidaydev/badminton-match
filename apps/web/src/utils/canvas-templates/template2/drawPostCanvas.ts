import { drawCoverFill, type PostCanvasOptions } from '../../canvasPost'
import { CANVAS_COLORS as C } from '../../../config/canvas'

const FONT   = '"Barlow Condensed", "Arial Narrow", Impact, sans-serif'
const NAVY   = '#09264D'
const YELLOW = '#FFC700'
const WHITE  = '#FFFFFF'

// Classic sports-logo outlined text: thick navy border + white fill
function drawSportsText(
  ctx: CanvasRenderingContext2D,
  text: string,
  x: number,
  y: number,
  size: number,
) {
  ctx.font = `italic 900 ${size}px ${FONT}`
  ctx.textBaseline = 'alphabetic'
  ctx.textAlign = 'left'

  // 1. Dark drop shadow (no blur, offset down-right)
  ctx.fillStyle = 'rgba(0, 4, 20, 0.85)'
  ctx.fillText(text, x + 8, y + 10)

  // 2. Thick navy stroke — creates the surrounding border
  ctx.strokeStyle = NAVY
  ctx.lineWidth = size * 0.09
  ctx.lineJoin = 'miter'
  ctx.miterLimit = 3
  ctx.strokeText(text, x, y)

  // 3. Navy fill — fills the interior solid navy before white layer
  ctx.fillStyle = NAVY
  ctx.fillText(text, x, y)

  // 4. White fill — foreground, sits cleanly on the navy interior
  ctx.fillStyle = WHITE
  ctx.fillText(text, x, y)
}

function drawDateV2(
  ctx: CanvasRenderingContext2D,
  canvasW: number,
  canvasH: number,
  day: string,
  month: string,
  year: string,
) {
  const DAY_SIZE   = 310
  const RIGHT_SIZE = 140  // OKT and 2026 same size

  ctx.save()
  ctx.textBaseline = 'alphabetic'
  ctx.textAlign = 'left'

  // Measure widths (no transform yet)
  ctx.font = `italic 900 ${DAY_SIZE}px ${FONT}`
  const dayW = ctx.measureText(day).width

  ctx.font = `italic 900 ${RIGHT_SIZE}px ${FONT}`
  const monthW = ctx.measureText(month).width
  const yearW  = ctx.measureText(year).width
  const rightColW = Math.max(monthW, yearW)

  const divGap    = 28
  const dividerX  = dayW + divGap
  const rightX    = dividerX + divGap + 6
  const totalW    = rightX + rightColW

  // Center horizontally; sit just inside the top frame band (~22% = 297px)
  const originX = (canvasW - totalW) / 2
  const originY = canvasH * 0.46   // leaves ~50px gap below top band

  ctx.translate(originX, originY)
  // NO extra skew — italic font provides the lean

  // Vertical layout:
  // · 15 baseline  = 0
  // · OKT cap-top aligns with 15 cap-top  → monthY = -(DAY_SIZE - RIGHT_SIZE) * 0.85
  // · 2026 baseline aligns with 15 baseline → yearY = 0
  const CAP_RATIO = 0.85
  const monthY = -((DAY_SIZE - RIGHT_SIZE) * CAP_RATIO)   // ≈ -144.5
  const yearY  = 0

  // ── Texts ──────────────────────────────────────────────────────────────────
  drawSportsText(ctx, day,   0,      0,      DAY_SIZE)
  drawSportsText(ctx, month, rightX, monthY, RIGHT_SIZE)
  drawSportsText(ctx, year,  rightX, yearY,  RIGHT_SIZE)

  // ── Yellow vertical divider (thick, tapered top & bottom) ─────────────────
  const divX = dividerX + divGap / 2
  const capH = DAY_SIZE * CAP_RATIO
  ctx.beginPath()
  ctx.moveTo(divX, -(capH + 12))
  ctx.lineTo(divX, DAY_SIZE * 0.08)
  ctx.strokeStyle = YELLOW
  ctx.lineWidth   = 12
  ctx.lineCap     = 'butt'
  ctx.stroke()

  // ── Top diagonal slash (upper-left of 15, angled ↗) ───────────────────────
  ctx.beginPath()
  ctx.moveTo(-44, -(capH * 0.72))
  ctx.lineTo(62,  -(capH * 0.92))
  ctx.strokeStyle = YELLOW
  ctx.lineWidth   = 10
  ctx.lineCap     = 'butt'
  ctx.stroke()

  // ── Bottom diagonal slash (lower-left, shorter) ────────────────────────────
  ctx.beginPath()
  ctx.moveTo(-28, DAY_SIZE * 0.1 + 30)
  ctx.lineTo(48,  DAY_SIZE * 0.1 + 8)
  ctx.strokeStyle = YELLOW
  ctx.lineWidth   = 8
  ctx.lineCap     = 'butt'
  ctx.stroke()

  ctx.restore()
}

export function drawPostCanvas(options: PostCanvasOptions) {
  const { canvas, userPhoto, photoOffset, photoZoom, overlays, date } = options
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, canvas.width, canvas.height)

  // Layer 1: user photo
  if (userPhoto) {
    drawCoverFill(ctx, userPhoto, canvas.width, canvas.height, photoOffset.x, photoOffset.y, photoZoom)
  } else {
    ctx.fillStyle = NAVY
    ctx.fillRect(0, 0, canvas.width, canvas.height)
  }

  // Layer 2: full-canvas frame PNG overlay
  if (overlays.footer) {
    ctx.drawImage(overlays.footer, 0, 0, canvas.width, canvas.height)
  }

  // Layer 3: sports-logo date
  if (date) {
    drawDateV2(ctx, canvas.width, canvas.height, date.day, date.month, date.year)
  }
}
