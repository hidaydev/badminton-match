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

export function drawBracketRoundCover(
  canvas: HTMLCanvasElement,
  roundTitle: string,
  matchRows: { label: string; nameA: string; nameB: string; scoreA: number | null; scoreB: number | null }[],
  summaryBg: HTMLImageElement | undefined,
  logo: HTMLImageElement | undefined,
  sponsor: HTMLImageElement | undefined,
) {
  const W = 1080
  const H = 1350
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, W, H)

  if (summaryBg) {
    ctx.drawImage(summaryBg, 0, 0, W, H)
  } else {
    ctx.fillStyle = '#0f172a'
    ctx.fillRect(0, 0, W, H)
  }

  drawHeader(ctx, W, logo)

  const ROW_H = 130
  const ROW_GAP = 12
  const CARD_PAD_TOP = 60
  const CARD_PAD_BOT = 60
  const TITLE_H = 160
  const CARD_X = 60
  const CARD_W = W - CARD_X * 2
  const CARD_H = CARD_PAD_TOP + TITLE_H + matchRows.length * (ROW_H + ROW_GAP) - ROW_GAP + CARD_PAD_BOT
  const CARD_Y = (H - CARD_H) / 2 + 60

  ctx.save()
  ctx.fillStyle = 'rgba(4,7,14,0.85)'
  ctx.beginPath()
  ctx.roundRect(CARD_X, CARD_Y, CARD_W, CARD_H, 32)
  ctx.fill()
  ctx.restore()

  if (sponsor) {
    const sH = 60
    const sW = sH * (sponsor.naturalWidth / sponsor.naturalHeight)
    ctx.drawImage(sponsor, (W - sW) / 2, CARD_Y + 18, sW, sH)
  }

  // Round title
  ctx.save()
  ctx.font = 'bold 80px Arial, sans-serif'
  ctx.fillStyle = '#facc15'
  ctx.textAlign = 'center'
  ctx.letterSpacing = '3px'
  ctx.fillText(roundTitle, W / 2, CARD_Y + CARD_PAD_TOP + 100)
  ctx.restore()

  // Divider
  ctx.save()
  ctx.strokeStyle = 'rgba(250,204,21,0.25)'
  ctx.lineWidth = 1.5
  ctx.beginPath()
  ctx.moveTo(CARD_X + 60, CARD_Y + CARD_PAD_TOP + TITLE_H - 10)
  ctx.lineTo(CARD_X + CARD_W - 60, CARD_Y + CARD_PAD_TOP + TITLE_H - 10)
  ctx.stroke()
  ctx.restore()

  const INNER_X = CARD_X + 50
  const INNER_W = CARD_W - 100
  const SCORE_W = 160
  const SCORE_CX = W / 2
  const NAME_MAX_W = (INNER_W - SCORE_W) / 2 - 20

  matchRows.forEach((row, i) => {
    const rowY = CARD_Y + CARD_PAD_TOP + TITLE_H + i * (ROW_H + ROW_GAP)
    const baseline = rowY + ROW_H * 0.62

    // Row background
    ctx.save()
    ctx.fillStyle = 'rgba(255,255,255,0.03)'
    ctx.beginPath()
    ctx.roundRect(CARD_X + 16, rowY + 4, CARD_W - 32, ROW_H - 8, 12)
    ctx.fill()
    ctx.restore()

    // Match label
    ctx.save()
    ctx.font = 'bold 22px monospace'
    ctx.fillStyle = '#475569'
    ctx.textAlign = 'left'
    ctx.letterSpacing = '1px'
    ctx.fillText(row.label, INNER_X, rowY + 28)
    ctx.restore()

    // Team A (right-aligned to score center)
    ctx.save()
    ctx.font = 'bold 38px Arial, sans-serif'
    ctx.fillStyle = '#e2e8f0'
    ctx.textAlign = 'right'
    let nameA = row.nameA
    while (ctx.measureText(nameA).width > NAME_MAX_W && nameA.length > 1) nameA = nameA.slice(0, -1)
    if (nameA !== row.nameA) nameA += '…'
    ctx.fillText(nameA, SCORE_CX - SCORE_W / 2 - 18, baseline)
    ctx.restore()

    // Score
    ctx.save()
    ctx.font = 'bold 38px monospace'
    ctx.fillStyle = '#facc15'
    ctx.textAlign = 'center'
    const scoreText = row.scoreA !== null && row.scoreB !== null ? `${row.scoreA}–${row.scoreB}` : 'vs'
    ctx.fillText(scoreText, SCORE_CX, baseline)
    ctx.restore()

    // Team B (left-aligned from score center)
    ctx.save()
    ctx.font = 'bold 38px Arial, sans-serif'
    ctx.fillStyle = '#e2e8f0'
    ctx.textAlign = 'left'
    let nameB = row.nameB
    while (ctx.measureText(nameB).width > NAME_MAX_W && nameB.length > 1) nameB = nameB.slice(0, -1)
    if (nameB !== row.nameB) nameB += '…'
    ctx.fillText(nameB, SCORE_CX + SCORE_W / 2 + 18, baseline)
    ctx.restore()
  })
}

export function drawPositionPost(
  canvas: HTMLCanvasElement,
  photo: HTMLImageElement,
  positionLabel: string,
  name: string,
  logo: HTMLImageElement | undefined,
  chevrons: HTMLImageElement | undefined,
  sponsor: HTMLImageElement | undefined,
) {
  const W = 1080
  const H = 1350
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, W, H)

  drawCoverFill(ctx, photo, W, H, 0, 0)

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

  drawHeader(ctx, W, logo)

  // Soft gradient — starts high, fades very gradually
  const gradStart = H * 0.52
  const grad = ctx.createLinearGradient(0, gradStart, 0, H)
  grad.addColorStop(0, 'rgba(0,0,0,0)')
  grad.addColorStop(0.45, 'rgba(0,0,0,0.55)')
  grad.addColorStop(0.72, 'rgba(0,0,0,0.85)')
  grad.addColorStop(1, 'rgba(0,0,0,0.95)')
  ctx.fillStyle = grad
  ctx.fillRect(0, gradStart, W, H - gradStart)

  const footerY = H - 320

  if (sponsor) {
    const sH = 52
    const sW = sH * (sponsor.naturalWidth / sponsor.naturalHeight)
    ctx.drawImage(sponsor, (W - sW) / 2, footerY + 10, sW, sH)
  }

  // Position label — bigger, more space below sponsor
  ctx.save()
  ctx.font = 'bold 40px monospace'
  ctx.fillStyle = '#facc15'
  ctx.textAlign = 'center'
  ctx.letterSpacing = '8px'
  ctx.fillText(positionLabel, W / 2, footerY + 115)
  ctx.restore()

  // Name — big, generous space below label
  ctx.save()
  ctx.font = 'bold 96px Arial, sans-serif'
  ctx.fillStyle = '#ffffff'
  ctx.textAlign = 'center'
  const maxW = W - 100
  let displayName = name
  while (ctx.measureText(displayName).width > maxW && displayName.length > 1) displayName = displayName.slice(0, -1)
  if (displayName !== name) displayName += '…'
  ctx.fillText(displayName, W / 2, footerY + 240)
  ctx.restore()
}
