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
  const DAY_SIZE   = 360
  const RIGHT_SIZE = 140
  const CAP_RATIO  = 0.85

  ctx.save()
  ctx.textBaseline = 'alphabetic'
  ctx.textAlign = 'left'

  // Measure widths before any transform
  ctx.font = `italic 900 ${DAY_SIZE}px ${FONT}`
  const dayW = ctx.measureText(day).width

  ctx.font = `italic 900 ${RIGHT_SIZE}px ${FONT}`
  const monthW    = ctx.measureText(month).width
  const yearW     = ctx.measureText(year).width
  const rightColW = Math.max(monthW, yearW)

  const divGap = 28
  const dividerX = dayW + divGap
  const rightX   = dividerX + divGap + 6
  const totalW   = rightX + rightColW
  const compH    = DAY_SIZE * CAP_RATIO   // ≈ 263px — full cap height

  // Rotate around the composition's visual center
  const cx = canvasW / 2
  const cy = canvasH * 0.42

  ctx.translate(cx, cy)
  ctx.rotate(-10 * Math.PI / 180)   // tilt whole logo upward-right like reference

  // Draw origin: top-left of bounding box at (-totalW/2, -compH)
  // → baseline of 15 at y = 0 relative to this translate
  const dx = -totalW / 2 + 50   // shift slightly right
  const dy = compH * 0.5   // vertical offset so composition is vertically centered

  const monthY = -((DAY_SIZE - RIGHT_SIZE) * CAP_RATIO)  // OKT top aligns with 15 top
  const yearY  = monthY + RIGHT_SIZE * CAP_RATIO - 8    // very tight, slight overlap

  // ── All elements share the same italic shear ──────────────────────────────
  ctx.save()
  ctx.transform(1, 0, -0.38, 1, 0, 0)  // single italic shear, same for all elements

  drawSportsText(ctx, day,   dx - 10,     dy - 80,     DAY_SIZE)
  drawSportsText(ctx, month, dx + rightX, dy + monthY, RIGHT_SIZE)
  drawSportsText(ctx, year,  dx + rightX, dy + yearY,  RIGHT_SIZE)

  // Yellow vertical divider
  const divX = dx + dividerX + divGap / 2
  ctx.beginPath()
  ctx.moveTo(divX, dy - compH - 12)
  ctx.lineTo(divX, dy + DAY_SIZE * 0.08)
  ctx.strokeStyle = YELLOW
  ctx.lineWidth   = 20
  ctx.lineCap     = 'butt'
  ctx.stroke()

  // Top diagonal slash
  ctx.beginPath()
  ctx.moveTo(dx - 44, dy - compH * 0.72)
  ctx.lineTo(dx + 62, dy - compH * 0.92)
  ctx.strokeStyle = YELLOW
  ctx.lineWidth   = 10
  ctx.lineCap     = 'butt'
  ctx.stroke()

  // Bottom diagonal slash
  ctx.beginPath()
  ctx.moveTo(dx - 28, dy + DAY_SIZE * 0.1 + 30)
  ctx.lineTo(dx + 48, dy + DAY_SIZE * 0.1 + 8)
  ctx.strokeStyle = YELLOW
  ctx.lineWidth   = 8
  ctx.lineCap     = 'butt'
  ctx.stroke()

  ctx.restore()

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
