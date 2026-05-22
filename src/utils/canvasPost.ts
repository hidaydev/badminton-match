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
  const logoTop = (HEADER_H - LOGO_H) / 2
  const textY = HEADER_H / 2 + fontSize * 0.38
  const label = 'MAJADU INTERNAL TOURNAMENT 2026'

  ctx.font = `bold ${fontSize}px Arial, sans-serif`
  ctx.letterSpacing = '1.5px'
  ctx.fillStyle = '#ffffff'

  // Left side: right-aligned ending at logo
  ctx.textAlign = 'right'
  ctx.fillText(label, (canvasW - logoW) / 2 - centerPad, textY)

  // Right side: left-aligned starting at logo
  ctx.textAlign = 'left'
  ctx.fillText(label, (canvasW + logoW) / 2 + centerPad, textY)

  if (logo) {
    ctx.drawImage(logo, (canvasW - logoW) / 2, logoTop, logoW, LOGO_H)
  }
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
  const W = 1080
  const H = 1350
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
  drawHeader(ctx, W, logo)

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
  ctx.fillStyle = '#ffffff'
  ctx.textAlign = 'left'
  let nameA = pairAName
  while (ctx.measureText(nameA).width > maxNameW && nameA.length > 1) nameA = nameA.slice(0, -1)
  if (nameA !== pairAName) nameA += '…'
  ctx.fillText(nameA, 60, rowY)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 36px Arial, sans-serif'
  ctx.fillStyle = '#ffffff'
  ctx.textAlign = 'right'
  let nameB = pairBName
  while (ctx.measureText(nameB).width > maxNameW && nameB.length > 1) nameB = nameB.slice(0, -1)
  if (nameB !== pairBName) nameB += '…'
  ctx.fillText(nameB, W - 60, rowY)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 42px monospace'
  ctx.fillStyle = '#facc15'
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
  ctx.fillStyle = '#64748b'
  ctx.textAlign = 'center'
  ctx.fillText(subtitle, W / 2, footerY + 205)
  ctx.restore()
}
