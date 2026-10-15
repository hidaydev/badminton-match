import { drawCoverFill, drawDate, type PostCanvasOptions } from '../../canvasPost'
import { CANVAS_COLORS as C } from '../../../config/canvas'

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

  // Layer 3: date (same fonts and layout as template 1)
  if (date) {
    drawDate(ctx, canvas.width, date.day, date.month, date.year, overlays.brushStroke)
  }
}
