import { drawCoverFill, type PostCanvasOptions } from '../../canvasPost'
import { CANVAS_COLORS as C } from '../../../config/canvas'

const FONT_STACK   = '"Anton", Impact, sans-serif'
const FONT_WEIGHT  = '400'
const ITALIC       = false
const NAVY   = '#09264D'
const YELLOW = '#FFC700'
const WHITE  = '#FFFFFF'

const OUTLINE      = 4   // navy outline thickness (px)
const BLOCK_DEPTH  = 13  // 3D block extrusion depth (px)
const BLOCK_COLOR  = '#09264D'  // navy block shadow

function makeGrainPattern(ctx: CanvasRenderingContext2D, size = 64): CanvasPattern {
  const off = document.createElement('canvas')
  off.width = off.height = size
  const c = off.getContext('2d')!
  const img = c.createImageData(size, size)
  for (let i = 0; i < img.data.length; i += 4) {
    const v = 210 + Math.random() * 45   // white-ish (210–255)
    img.data[i]     = v
    img.data[i + 1] = v
    img.data[i + 2] = v
    img.data[i + 3] = 255
  }
  c.putImageData(img, 0, 0)
  return ctx.createPattern(off, 'repeat')!
}

function drawSportsText(
  ctx: CanvasRenderingContext2D,
  text: string,
  x: number,
  y: number,
  size: number,
  fontStack: string,
  italic: boolean,
  weight = '900',
) {
  const style = italic ? `italic ${weight}` : weight
  ctx.font = `${style} ${size}px ${fontStack}`
  ctx.textBaseline = 'alphabetic'
  ctx.textAlign = 'left'
  ctx.shadowColor   = 'rgba(0,0,0,0.7)'
  ctx.shadowBlur    = 24
  ctx.shadowOffsetX = 4
  ctx.shadowOffsetY = 4
  ctx.fillStyle = WHITE
  ctx.fillText(text, x, y)
  ctx.shadowColor = 'transparent'
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
  weight = '900',
) {
  const DAY_SIZE   = 190
  const RIGHT_SIZE = 76
  const CAP_RATIO  = 0.85
  const italicStyle = italic ? `italic ${weight}` : weight

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
  const yearY  = monthY + RIGHT_SIZE * CAP_RATIO + 8

  ctx.save()
  ctx.transform(1, 0, -0.38, 1, 0, 0)

  let charX = dx - 9
  for (const char of day) {
    drawSportsText(ctx, char, charX, dy - 40, DAY_SIZE, fontStack, italic, weight)
    ctx.font = `${italicStyle} ${DAY_SIZE}px ${fontStack}`
    charX += ctx.measureText(char).width - 1
  }
  let mX = dx + rightX
  for (const char of month) {
    drawSportsText(ctx, char, mX, dy + monthY, RIGHT_SIZE, fontStack, italic, weight)
    ctx.font = `${italicStyle} ${RIGHT_SIZE}px ${fontStack}`
    mX += ctx.measureText(char).width + 6
  }
  let yX = dx + rightX
  for (const char of year) {
    drawSportsText(ctx, char, yX, dy + yearY, RIGHT_SIZE, fontStack, italic, weight)
    ctx.font = `${italicStyle} ${RIGHT_SIZE}px ${fontStack}`
    yX += ctx.measureText(char).width + 6
  }

  const divX   = dx + dividerX + divGap / 2 - 10
  const divTop = dy + monthY - RIGHT_SIZE * CAP_RATIO - 6
  const divBot = dy + yearY + 4
  const lean   = 0

  // Yellow slash with shadow + gradient
  ctx.shadowColor   = 'rgba(0,0,0,0.7)'
  ctx.shadowBlur    = 24
  ctx.shadowOffsetX = 4
  ctx.shadowOffsetY = 4
  ctx.beginPath()
  ctx.moveTo(divX + lean, divTop)
  ctx.lineTo(divX,        divBot)
  ctx.strokeStyle = YELLOW
  ctx.lineWidth   = 12
  ctx.lineCap     = 'square'
  ctx.stroke()
  ctx.shadowColor = 'transparent'

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
  drawDateWithFont(ctx, canvasW, canvasH * 0.22, day, month, year, FONT_STACK, ITALIC, FONT_WEIGHT)
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
