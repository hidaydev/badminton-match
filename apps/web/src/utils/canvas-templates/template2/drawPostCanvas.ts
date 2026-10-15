import { drawCoverFill, type PostCanvasOptions } from '../../canvasPost'
import { CANVAS_COLORS as C } from '../../../config/canvas'

const FONT_STACK = '"Squada One", Impact, sans-serif'
const ITALIC     = false
const NAVY   = '#09264D'
const YELLOW = '#FFC700'
const WHITE  = '#FFFFFF'

const OUTLINE      = 4   // navy outline thickness (px)
const BLOCK_DEPTH  = 13  // 3D block extrusion depth (px)
const BLOCK_COLOR  = '#09264D'  // navy block shadow

function drawSportsText(
  ctx: CanvasRenderingContext2D,
  text: string,
  x: number,
  y: number,
  size: number,
  fontStack: string,
  italic: boolean,
) {
  const style = italic ? 'italic 900' : '900'
  ctx.font = `${style} ${size}px ${fontStack}`
  ctx.textBaseline = 'alphabetic'
  ctx.textAlign = 'left'
  ctx.lineJoin = 'miter'
  ctx.miterLimit = 3

  // 3D block layers — drawn back to front (deepest first)
  for (let i = BLOCK_DEPTH; i >= 1; i--) {
    ctx.strokeStyle = BLOCK_COLOR
    ctx.lineWidth = OUTLINE * 2
    ctx.strokeText(text, x + i, y + i)
    ctx.fillStyle = BLOCK_COLOR
    ctx.fillText(text, x + i, y + i)
  }

  // Top layer: navy outline + white fill
  ctx.strokeStyle = NAVY
  ctx.lineWidth = OUTLINE * 2
  ctx.strokeText(text, x, y)
  ctx.fillStyle = WHITE
  ctx.fillText(text, x, y)
}

function drawDateWithFont(
  ctx: CanvasRenderingContext2D,
  canvasW: number,
  centerY: number,
  day: string,
  month: string,
  year: string,
  fontStack: string,
  italic: boolean,
) {
  const DAY_SIZE   = 220
  const RIGHT_SIZE = 88
  const CAP_RATIO  = 0.85
  const italicStyle = italic ? 'italic 900' : '900'

  ctx.save()
  ctx.textBaseline = 'alphabetic'
  ctx.textAlign = 'left'

  ctx.font = `${italicStyle} ${DAY_SIZE}px ${fontStack}`
  const dayW = ctx.measureText(day).width

  ctx.font = `${italicStyle} ${RIGHT_SIZE}px ${fontStack}`
  const monthW    = ctx.measureText(month).width
  const yearW     = ctx.measureText(year).width
  const rightColW = Math.max(monthW, yearW)

  const divGap   = 14
  const dividerX = dayW + divGap
  const rightX   = dividerX + divGap + 6
  const totalW   = rightX + rightColW
  const compH    = DAY_SIZE * CAP_RATIO

  ctx.translate(canvasW / 2, centerY)
  ctx.rotate(-10 * Math.PI / 180)

  const dx = -totalW / 2
  const dy = compH * 0.5

  const monthY = -((DAY_SIZE - RIGHT_SIZE) * CAP_RATIO)
  const yearY  = monthY + RIGHT_SIZE * CAP_RATIO + 2

  ctx.save()
  ctx.transform(1, 0, -0.38, 1, 0, 0)

  let charX = dx - 9
  for (const char of day) {
    drawSportsText(ctx, char, charX, dy - 70, DAY_SIZE, fontStack, italic)
    ctx.font = `${italicStyle} ${DAY_SIZE}px ${fontStack}`
    charX += ctx.measureText(char).width - 1
  }
  let mX = dx + rightX
  for (const char of month) {
    drawSportsText(ctx, char, mX, dy + monthY, RIGHT_SIZE, fontStack, italic)
    ctx.font = `${italicStyle} ${RIGHT_SIZE}px ${fontStack}`
    mX += ctx.measureText(char).width + 6
  }
  let yX = dx + rightX
  for (const char of year) {
    drawSportsText(ctx, char, yX, dy + yearY, RIGHT_SIZE, fontStack, italic)
    ctx.font = `${italicStyle} ${RIGHT_SIZE}px ${fontStack}`
    yX += ctx.measureText(char).width + 6
  }

  const divX   = dx + dividerX + divGap / 2 - 10
  const divTop = dy + monthY - RIGHT_SIZE * CAP_RATIO + 12
  const divBot = dy + yearY + 6
  const lean   = 0

  // Block shadow for slash
  ctx.lineWidth = 12 + OUTLINE * 2
  ctx.lineCap   = 'square'
  for (let i = BLOCK_DEPTH; i >= 1; i--) {
    ctx.beginPath()
    ctx.moveTo(divX + lean + i, divTop + i)
    ctx.lineTo(divX        + i, divBot + i)
    ctx.strokeStyle = BLOCK_COLOR
    ctx.stroke()
  }

  // Navy outline
  ctx.beginPath()
  ctx.moveTo(divX + lean, divTop)
  ctx.lineTo(divX,        divBot)
  ctx.strokeStyle = NAVY
  ctx.stroke()

  // Yellow fill
  ctx.beginPath()
  ctx.moveTo(divX + lean, divTop)
  ctx.lineTo(divX,        divBot)
  ctx.strokeStyle = YELLOW
  ctx.lineWidth   = 12
  ctx.stroke()

  ctx.restore()
  ctx.restore()
}

function drawDateV2(
  ctx: CanvasRenderingContext2D,
  canvasW: number,
  canvasH: number,
  day: string,
  month: string,
  year: string,
) {
  drawDateWithFont(ctx, canvasW, canvasH * 0.22, day, month, year, FONT_STACK, ITALIC)
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
