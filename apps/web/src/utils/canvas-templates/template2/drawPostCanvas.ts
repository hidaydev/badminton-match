import { drawCoverFill, type PostCanvasOptions } from '../../canvasPost'
import { CANVAS_COLORS as C } from '../../../config/canvas'

const FONT      = '"Barlow Condensed", "Arial Narrow", Impact, sans-serif'
const NAVY      = '#09264D'
const DARK_NAVY = '#061430'
const YELLOW    = '#FFC700'
const WHITE     = '#FFFFFF'

// Stacked offset fills — no strokeText (prevents edge blur on dark bg)
function drawLayeredText(
  ctx: CanvasRenderingContext2D,
  text: string,
  x: number,
  y: number,
  size: number,
) {
  ctx.font = `italic 900 ${size}px ${FONT}`
  ctx.textBaseline = 'alphabetic'
  ctx.textAlign = 'left'

  // Far shadow — gives depth against dark bg
  ctx.fillStyle = 'rgba(0, 4, 18, 0.85)'
  ctx.fillText(text, x + 10, y + 13)

  // Navy extrusion layers (back → front, darker at base)
  for (let i = 8; i >= 1; i--) {
    ctx.fillStyle = i > 4 ? DARK_NAVY : NAVY
    ctx.fillText(text, x + i * 0.75, y + i * 0.95)
  }

  // White foreground — sits cleanly on top
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
  const MONTH_SIZE = 104
  const YEAR_SIZE  = 92

  ctx.save()
  ctx.textBaseline = 'alphabetic'
  ctx.textAlign = 'left'

  // Measure in default state first
  ctx.font = `italic 900 ${DAY_SIZE}px ${FONT}`
  const dayW = ctx.measureText(day).width

  ctx.font = `italic 900 ${MONTH_SIZE}px ${FONT}`
  const monthW = ctx.measureText(month).width

  ctx.font = `italic 900 ${YEAR_SIZE}px ${FONT}`
  const yearW = ctx.measureText(year).width

  const rightColW  = Math.max(monthW, yearW)
  const divGap     = 26
  const dividerX   = dayW + divGap
  const rightX     = dividerX + divGap + 4
  const totalWidth = rightX + rightColW

  // Center horizontally; place in upper photo area (just below top frame band ~22%)
  const originX = (canvasW - totalWidth) / 2
  const originY = canvasH * 0.38   // ~22% top band + some margin

  ctx.translate(originX, originY)
  // Slight rightward-upward lean
  ctx.transform(1, -0.05, 0, 1, 0, 0)

  // Vertical positions relative to origin (= 15 baseline)
  const dayY   = 0
  // OKT baseline: align its cap-height with top of 15
  const capH15  = DAY_SIZE * 0.85
  const capHOKT = MONTH_SIZE * 0.85
  const monthY  = -(capH15 - capHOKT)         // ≈ top of 15 = top of OKT
  const yearY   = monthY + YEAR_SIZE + 12

  // ── Texts ──────────────────────────────────────────────────────────────────
  drawLayeredText(ctx, day,   0,      dayY,   DAY_SIZE)
  drawLayeredText(ctx, month, rightX, monthY, MONTH_SIZE)
  drawLayeredText(ctx, year,  rightX, yearY,  YEAR_SIZE)

  // ── Yellow vertical divider ────────────────────────────────────────────────
  const divX = dividerX + divGap / 2
  ctx.beginPath()
  ctx.moveTo(divX, -(capH15 + 10))
  ctx.lineTo(divX, DAY_SIZE * 0.1)
  ctx.strokeStyle = YELLOW
  ctx.lineWidth   = 6
  ctx.lineCap     = 'butt'
  ctx.stroke()

  // ── Top diagonal slash (upper-left of 15) ─────────────────────────────────
  ctx.beginPath()
  ctx.moveTo(-38, -(capH15 * 0.78))
  ctx.lineTo(52,  -(capH15 * 0.96))
  ctx.strokeStyle = YELLOW
  ctx.lineWidth   = 8
  ctx.lineCap     = 'butt'
  ctx.stroke()

  // ── Bottom diagonal slash (lower-left, shorter) ────────────────────────────
  ctx.beginPath()
  ctx.moveTo(-24, dayY + 42)
  ctx.lineTo(42,  dayY + 22)
  ctx.strokeStyle = YELLOW
  ctx.lineWidth   = 6
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
    ctx.fillStyle = C.bgDark
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
