import { drawCoverFill, type PostCanvasOptions } from '../../canvasPost'
import { CANVAS_COLORS as C } from '../../../config/canvas'

const FONT = '"Barlow Condensed", "Arial Narrow", Impact, sans-serif'
const NAVY  = '#09264D'
const YELLOW = '#FFC700'
const WHITE  = '#FFFFFF'
const SHADOW = 'rgba(30, 50, 75, 0.25)'

function drawLayeredText(
  ctx: CanvasRenderingContext2D,
  text: string,
  x: number,
  y: number,
  size: number,
) {
  ctx.font = `italic 900 ${size}px ${FONT}`
  ctx.textBaseline = 'alphabetic'

  // 1 — gray drop shadow
  ctx.fillStyle = SHADOW
  ctx.fillText(text, x + 6, y + 8)

  // 2 — thick navy stroke for chunky outline/backing
  ctx.strokeStyle = NAVY
  ctx.lineWidth = size * 0.13
  ctx.lineJoin = 'round'
  ctx.strokeText(text, x, y)

  // 3 — navy fill offset for depth dimension
  ctx.fillStyle = NAVY
  ctx.fillText(text, x + 4, y + 4)

  // 4 — white foreground
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
  const DAY_SIZE   = 280
  const MONTH_SIZE = 92
  const YEAR_SIZE  = 80

  ctx.save()

  // Anchor point: lower-left photo area, above the bottom frame band
  const originX = 90
  const originY = canvasH * 0.755

  ctx.translate(originX, originY)
  // Slight rightward-upward lean for the sports aesthetic
  ctx.transform(1, -0.055, 0, 1, 0, 0)

  ctx.textBaseline = 'alphabetic'

  // Measure widths for layout
  ctx.font = `italic 900 ${DAY_SIZE}px ${FONT}`
  const dayW = ctx.measureText(day).width

  ctx.font = `italic 900 ${MONTH_SIZE}px ${FONT}`
  const monthW = ctx.measureText(month).width

  ctx.font = `italic 900 ${YEAR_SIZE}px ${FONT}`
  const yearW = ctx.measureText(year).width

  const divGap   = 24
  const dividerX = dayW + divGap
  const rightX   = dividerX + divGap + 4

  // Vertical positions (relative to origin = day baseline)
  const dayY   = 0
  const monthY = -(DAY_SIZE * 0.58)
  const yearY  = monthY + YEAR_SIZE + 14

  // ── Draw layered texts ────────────────────────────────────────────────────
  drawLayeredText(ctx, day,   0,      dayY,   DAY_SIZE)
  drawLayeredText(ctx, month, rightX, monthY, MONTH_SIZE)
  drawLayeredText(ctx, year,  rightX, yearY,  YEAR_SIZE)

  // ── Yellow vertical divider ───────────────────────────────────────────────
  ctx.beginPath()
  ctx.moveTo(dividerX + divGap / 2, -(DAY_SIZE * 0.88))
  ctx.lineTo(dividerX + divGap / 2, DAY_SIZE * 0.08)
  ctx.strokeStyle = YELLOW
  ctx.lineWidth   = 5
  ctx.lineCap     = 'butt'
  ctx.stroke()

  // ── Yellow diagonal slash — top-left of day ───────────────────────────────
  ctx.beginPath()
  ctx.moveTo(-32, -(DAY_SIZE * 0.82))
  ctx.lineTo(46,  -(DAY_SIZE * 0.96))
  ctx.strokeStyle = YELLOW
  ctx.lineWidth   = 7
  ctx.lineCap     = 'butt'
  ctx.stroke()

  // ── Yellow diagonal slash — bottom-left of day (shorter) ─────────────────
  ctx.beginPath()
  ctx.moveTo(-22, dayY + 36)
  ctx.lineTo(38,  dayY + 16)
  ctx.strokeStyle = YELLOW
  ctx.lineWidth   = 5
  ctx.lineCap     = 'butt'
  ctx.stroke()

  ctx.restore()
}

export function drawPostCanvas(options: PostCanvasOptions) {
  const { canvas, userPhoto, photoOffset, photoZoom, overlays, date } = options
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, canvas.width, canvas.height)

  // Layer 1: user photo (cover-fill with pan/zoom)
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
