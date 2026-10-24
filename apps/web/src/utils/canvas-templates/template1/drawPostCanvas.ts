import { drawCoverFill, drawDate, drawHeader, type PostCanvasOptions } from '../../canvasPost'
import { CANVAS_COLORS as C } from '../../../config/canvas'

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
