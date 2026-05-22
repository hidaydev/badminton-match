// src/utils/canvasPost.ts

const HEADER_H = 90
const LOGO_H = 28

export function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve(img)
    img.onerror = reject
    img.src = src
  })
}

export function drawCoverFill(
  ctx: CanvasRenderingContext2D,
  img: HTMLImageElement,
  canvasW: number,
  canvasH: number,
  offsetX: number,
  offsetY: number,
  zoom: number = 1,
) {
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
    { text: 'MAJADU INTERNAL TOURNAMENT 2026', color: '#ffffff' },
    { text: '  •  ', color: '#facc15' },
    { text: 'MAJADU INTERNAL TOURNAMENT 2026', color: '#ffffff' },
    { text: '  •  ', color: '#facc15' },
    { text: 'MAJADU INTERNAL TOURNAMENT 2026', color: '#ffffff' },
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

export function drawHeader(
  ctx: CanvasRenderingContext2D,
  canvasW: number,
  logo: HTMLImageElement | undefined,
) {
  const grad = ctx.createLinearGradient(0, 0, 0, HEADER_H)
  grad.addColorStop(0, 'rgba(10,10,20,0.92)')
  grad.addColorStop(1, 'rgba(0,0,0,0)')
  ctx.fillStyle = grad
  ctx.fillRect(0, 0, canvasW, HEADER_H)

  const fontSize = 15
  const logoW = logo ? LOGO_H * (logo.naturalWidth / logo.naturalHeight) : 160
  const centerPad = 30
  const sideZoneW = (canvasW - logoW) / 2 - centerPad
  const logoTop = (HEADER_H - LOGO_H) / 2
  const textY = HEADER_H / 2 + fontSize * 0.38

  ctx.font = `bold ${fontSize}px Arial, sans-serif`
  ctx.letterSpacing = '1.5px'
  const fullText = 'MAJADU INTERNAL TOURNAMENT 2026  •  MAJADU INTERNAL TOURNAMENT 2026  •  MAJADU INTERNAL TOURNAMENT 2026'
  const totalW = ctx.measureText(fullText).width
  const clampedW = Math.min(totalW, sideZoneW)

  const leftStartX = (canvasW - logoW) / 2 - centerPad - clampedW
  drawSideText(ctx, leftStartX, textY, fontSize)

  const rightStartX = (canvasW + logoW) / 2 + centerPad
  drawSideText(ctx, rightStartX, textY, fontSize)

  if (logo) {
    ctx.drawImage(logo, (canvasW - logoW) / 2, logoTop, logoW, LOGO_H)
  }
}
