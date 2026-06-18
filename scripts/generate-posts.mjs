// scripts/generate-posts.mjs
// Batch-generates post.jpg (1080x1350) and story.jpg (1080x1920) for each
// date folder in /Users/hidaydev/Downloads/Majadu/Best/

import { createCanvas, loadImage, GlobalFonts } from '@napi-rs/canvas'
import { readdir, readFile, writeFile } from 'node:fs/promises'
import { join, resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { existsSync } from 'node:fs'

const __dirname = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(__dirname, '..')
const PUBLIC = join(ROOT, 'public')
const BEST_DIR = '/Users/hidaydev/Downloads/Majadu/Best'

// Register fonts from public/
GlobalFonts.registerFromPath(join(PUBLIC, 'Granesta.ttf'), 'Granesta')
GlobalFonts.registerFromPath(join(PUBLIC, 'edosz.ttf'), 'Edosz')
GlobalFonts.registerFromPath(join(PUBLIC, 'anton.ttf'), 'Anton')

const MONTHS = ['JAN','FEB','MAR','APR','MEI','JUN','JUL','AGU','SEP','OKT','NOV','DES']
const HEADER_H = 90
const LOGO_H = 28

function drawCoverFill(ctx, img, canvasW, canvasH, offsetX = 0, offsetY = 0, zoom = 1) {
  const scale = Math.max(canvasW / img.width, canvasH / img.height) * zoom
  const w = img.width * scale
  const h = img.height * scale
  const x = (canvasW - w) / 2 + offsetX
  const y = (canvasH - h) / 2 + offsetY
  ctx.drawImage(img, x, y, w, h)
}

function drawContainWithBlurBg(ctx, img, canvasW, canvasH) {
  // Blurred cover background
  ctx.save()
  ctx.filter = 'blur(24px) brightness(0.5)'
  drawCoverFill(ctx, img, canvasW, canvasH, 0, 0, 1)
  ctx.filter = 'none'
  ctx.restore()

  // Full image contained, centered
  const scale = Math.min(canvasW / img.width, canvasH / img.height)
  const w = img.width * scale
  const h = img.height * scale
  const x = (canvasW - w) / 2
  const y = (canvasH - h) / 2
  ctx.drawImage(img, x, y, w, h)
}

function drawSideText(ctx, startX, y, fontSize) {
  const segments = [
    { text: 'MAJADU FUN', color: '#ffffff' },
    { text: '  •  ', color: '#facc15' },
    { text: 'MAJADU FUN', color: '#ffffff' },
    { text: '  •  ', color: '#facc15' },
    { text: 'MAJADU FUN', color: '#ffffff' },
  ]
  ctx.font = `bold ${fontSize}px Arial, sans-serif`
  let x = startX
  for (const seg of segments) {
    ctx.fillStyle = seg.color
    ctx.textAlign = 'left'
    ctx.fillText(seg.text, x, y)
    x += ctx.measureText(seg.text).width
  }
}

function drawHeader(ctx, canvasW, logo) {
  const grad = ctx.createLinearGradient(0, 0, 0, HEADER_H)
  grad.addColorStop(0, 'rgba(10,10,20,0.92)')
  grad.addColorStop(1, 'rgba(0,0,0,0)')
  ctx.fillStyle = grad
  ctx.fillRect(0, 0, canvasW, HEADER_H)

  const fontSize = 15
  const logoW = logo ? LOGO_H * (logo.width / logo.height) : 160
  const centerPad = 30
  const sideZoneW = (canvasW - logoW) / 2 - centerPad
  const logoTop = (HEADER_H - LOGO_H) / 2
  const textY = HEADER_H / 2 + fontSize * 0.38

  ctx.font = `bold ${fontSize}px Arial, sans-serif`
  const fullText = 'MAJADU FUN  •  MAJADU FUN  •  MAJADU FUN'
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

function drawDate(ctx, canvasW, day, month, year, brushStroke) {
  const daySize = 200
  const monthSize = 82
  const yearSize = 72

  ctx.font = `${daySize}px Granesta, Impact, sans-serif`
  const dayW = ctx.measureText(day).width
  ctx.font = `${monthSize}px Granesta, Impact, sans-serif`
  const monthW = ctx.measureText(month).width
  ctx.font = `${yearSize}px Edosz, Impact, sans-serif`
  const yearW = ctx.measureText(year).width

  const rightColW = Math.max(monthW, yearW + 30) + 20
  const gapX = 16
  const totalW = dayW + gapX + rightColW
  const startX = (canvasW - totalW) / 2

  const dayH = daySize * 0.88
  const monthH = monthSize * 0.88
  const brushH = yearSize + 22
  const rightColH = monthH + 14 + brushH
  const topY = 150

  const dayBaselineY = topY + Math.max(dayH, rightColH) * 0.5 + dayH * 0.5
  const rightColX = startX + dayW + gapX
  const rightColTopY = topY + (Math.max(dayH, rightColH) - rightColH) / 2
  const monthBaselineY = rightColTopY + monthH
  const brushY = monthBaselineY + 4

  // Day — black shadow + yellow fill
  ctx.save()
  ctx.font = `${daySize}px Granesta, Impact, sans-serif`
  ctx.fillStyle = '#000000'
  ctx.fillText(day, startX + 5, dayBaselineY + 20)
  ctx.fillStyle = '#F5B400'
  ctx.fillText(day, startX, dayBaselineY + 15)
  ctx.restore()

  // Month — yellow stroke + black fill, rotated -5deg
  ctx.save()
  ctx.font = `${monthSize}px Granesta, Impact, sans-serif`
  const mCX = rightColX + monthW / 2
  const mCY = monthBaselineY - monthH / 2
  ctx.translate(mCX, mCY)
  ctx.rotate(-5 * Math.PI / 180)
  ctx.translate(-mCX, -mCY)
  ctx.strokeStyle = '#F5B400'
  ctx.lineWidth = 10
  ctx.lineJoin = 'round'
  ctx.strokeText(month, rightColX + 24, monthBaselineY + 30)
  ctx.fillStyle = '#111111'
  ctx.fillText(month, rightColX + 24, monthBaselineY + 30)
  ctx.restore()

  // Brush stroke background + year text
  const bW = rightColW + 160
  const bH = brushH + 110
  const bCX = rightColX + rightColW / 2
  const bCY = brushY + bH / 2 - 10
  ctx.save()
  ctx.translate(bCX, bCY)
  ctx.rotate(-6 * Math.PI / 180)
  if (brushStroke) {
    ctx.drawImage(brushStroke, -bW / 2, -bH / 2, bW, bH)
  } else {
    ctx.fillStyle = '#F5B400'
    ctx.fillRect(-bW / 2, -bH / 2, bW, bH)
  }
  ctx.font = `${yearSize}px Edosz, Impact, sans-serif`
  ctx.fillStyle = '#111111'
  ctx.textAlign = 'center'
  ctx.fillText(year, 0, yearSize * 0.22 - 5)
  ctx.restore()
}

async function generatePost(photoPath, date, overlays) {
  const W = 1080, H = 1350
  const canvas = createCanvas(W, H)
  const ctx = canvas.getContext('2d')

  // Photo — landscape: contain + blur bg; portrait: cover fill
  const photo = await loadImage(photoPath)
  const isLandscape = photo.width > photo.height
  if (isLandscape) {
    drawContainWithBlurBg(ctx, photo, W, H)
  } else {
    drawCoverFill(ctx, photo, W, H, 0, 0, 1)
  }

  // Date
  const { day, month, year } = date
  drawDate(ctx, W, day, month, year, overlays.brushStroke)

  // Chevrons
  if (overlays.chevrons) {
    const img = overlays.chevrons
    const h = 115
    const w = h * (img.width / img.height)
    ctx.drawImage(img, W - w - 30, H * 0.3, w, h)
  }

  // Header
  drawHeader(ctx, W, overlays.logo)

  // Footer
  if (overlays.footer) {
    const img = overlays.footer
    const h = W * (img.height / img.width)
    ctx.drawImage(img, 0, H - h, W, h)
  }

  return canvas
}

async function generateStory(postCanvas, overlays) {
  const W = 1080, H = 1920
  const canvas = createCanvas(W, H)
  const ctx = canvas.getContext('2d')

  // Background
  if (overlays.storyBg) {
    ctx.drawImage(overlays.storyBg, 0, 0, W, H)
  } else {
    ctx.fillStyle = '#F5B400'
    ctx.fillRect(0, 0, W, H)
  }

  // Post centered with padding, rounded corners + shadow
  const pad = 60
  const pW = W - pad * 2
  const pH = pW * (postCanvas.height / postCanvas.width)
  const pX = pad
  const pY = (H - pH) / 2
  const radius = 28

  // Shadow
  ctx.save()
  ctx.shadowColor = 'rgba(0,0,0,0.45)'
  ctx.shadowBlur = 40
  ctx.shadowOffsetY = 8
  ctx.fillStyle = '#000'
  ctx.beginPath()
  ctx.roundRect(pX, pY, pW, pH, radius)
  ctx.fill()
  ctx.restore()

  // Clip + draw post
  ctx.save()
  ctx.beginPath()
  ctx.roundRect(pX, pY, pW, pH, radius)
  ctx.clip()
  ctx.drawImage(postCanvas, pX, pY, pW, pH)
  ctx.restore()

  return canvas
}

async function main() {
  // Load overlay images
  console.log('Loading overlays...')
  const overlays = {}
  const overlayPaths = {
    logo: join(PUBLIC, 'instagram-logo.png'),
    footer: join(PUBLIC, 'instagram-footer.png'),
    brushStroke: join(PUBLIC, 'brush-stroke.png'),
    chevrons: join(PUBLIC, 'chevrons.png'),
    storyBg: join(PUBLIC, 'story-bg.png'),
  }
  for (const [key, path] of Object.entries(overlayPaths)) {
    if (existsSync(path)) {
      overlays[key] = await loadImage(path)
      console.log(`  ✓ ${key}`)
    } else {
      console.log(`  ✗ ${key} not found at ${path}`)
    }
  }

  // Get date folders
  const folders = (await readdir(BEST_DIR)).sort()
  console.log(`\nProcessing ${folders.length} date folders...\n`)

  for (const folder of folders) {
    const folderPath = join(BEST_DIR, folder)
    const photoPath = join(folderPath, '1.jpg')

    if (!existsSync(photoPath)) {
      console.log(`  ✗ ${folder}: no 1.jpg found, skipping`)
      continue
    }

    // Parse date from folder name (YYYY-MM-DD)
    const [year, mm, dd] = folder.split('-')
    const date = {
      day: String(parseInt(dd)),
      month: MONTHS[parseInt(mm) - 1],
      year,
    }

    try {
      // Check dimensions
      const probe = await loadImage(photoPath)
      const isLandscape = probe.width > probe.height
      const dimTag = isLandscape ? ` ⚠ LANDSCAPE (${probe.width}×${probe.height})` : ''

      // Generate post
      const postCanvas = await generatePost(photoPath, date, overlays)
      const postBuf = await postCanvas.encode('jpeg', 92)
      await writeFile(join(folderPath, 'post.jpg'), postBuf)

      // Generate story
      const storyCanvas = await generateStory(postCanvas, overlays)
      const storyBuf = await storyCanvas.encode('jpeg', 92)
      await writeFile(join(folderPath, 'story.jpg'), storyBuf)

      console.log(`  ✓ ${folder}  →  post.jpg + story.jpg${dimTag}`)
    } catch (err) {
      console.error(`  ✗ ${folder}: ${err.message}`)
    }
  }

  console.log('\nDone!')
}

main().catch(console.error)
