// src/pages/InstagramPostPage.tsx
import { useRef, useState, useEffect, useCallback, useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { instagramTemplates, type PostTemplate } from '../config/instagramTemplates'

const TEMPLATE = instagramTemplates[0]
const HEADER_H = 90
const LOGO_H = 28

const MONTHS = ['JAN','FEB','MAR','APR','MEI','JUN','JUL','AGU','SEP','OKT','NOV','DES']

function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve(img)
    img.onerror = reject
    img.src = src
  })
}

function drawCoverFill(
  ctx: CanvasRenderingContext2D,
  img: HTMLImageElement,
  canvasW: number,
  canvasH: number,
  offsetX: number,
  offsetY: number,
) {
  const scale = Math.max(canvasW / img.naturalWidth, canvasH / img.naturalHeight)
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
    { text: 'MAJADU FUN', color: '#ffffff' },
    { text: '  •  ', color: '#facc15' },
    { text: 'MAJADU FUN', color: '#ffffff' },
    { text: '  •  ', color: '#facc15' },
    { text: 'MAJADU FUN', color: '#ffffff' },
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

function drawHeader(
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


function drawDate(
  ctx: CanvasRenderingContext2D,
  canvasW: number,
  day: string,
  month: string,
  year: string,
  brushStroke?: HTMLImageElement,
) {
  const daySize = 200
  const monthSize = 82
  const yearSize = 72

  // Measure all parts to compute total width for centering
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

  // Vertical layout
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
  const yearBaselineY = brushY + yearSize * 0.88 + 6

  // Day — black shadow + yellow fill
  ctx.save()
  ctx.font = `${daySize}px Granesta, Impact, sans-serif`
  ctx.fillStyle = '#000000'
  ctx.fillText(day, startX + 5, dayBaselineY + 20)
  ctx.fillStyle = '#F5B400'
  ctx.fillText(day, startX, dayBaselineY + 15)
  ctx.restore()

  // Month — black, rotated -5deg
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
  ctx.fillText(year, 0, yearSize * 0.22)
  ctx.restore()
}

function drawCanvas(
  canvas: HTMLCanvasElement,
  _template: PostTemplate,
  userPhoto: HTMLImageElement | null,
  photoOffset: { x: number; y: number },
  overlays: { logo?: HTMLImageElement; footer?: HTMLImageElement; brushStroke?: HTMLImageElement },
  date: { day: string; month: string; year: string } | null,
) {
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, canvas.width, canvas.height)

  // Layer 1: user photo
  if (userPhoto) {
    drawCoverFill(ctx, userPhoto, canvas.width, canvas.height, photoOffset.x, photoOffset.y)
  } else {
    ctx.fillStyle = '#1e293b'
    ctx.fillRect(0, 0, canvas.width, canvas.height)
  }

  // Layer 2: date (below header and footer overlays)
  if (date) {
    drawDate(ctx, canvas.width, date.day, date.month, date.year, overlays.brushStroke)
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

export default function InstagramPostPage() {
  const navigate = useNavigate()
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)

  const [userPhoto, setUserPhoto] = useState<HTMLImageElement | null>(null)
  const [photoOffset, setPhotoOffset] = useState({ x: 0, y: 0 })
  const [overlays, setOverlays] = useState<{ logo?: HTMLImageElement; footer?: HTMLImageElement; brushStroke?: HTMLImageElement }>({})
  const [isDragging, setIsDragging] = useState(false)
  const [fontReady, setFontReady] = useState(false)
  const [dateValue, setDateValue] = useState(() => new Date().toISOString().split('T')[0])
  const dragStart = useRef<{ x: number; y: number; ox: number; oy: number } | null>(null)

  const parsedDate = useMemo(() => {
    const [year, month, day] = dateValue.split('-')
    return { day: String(parseInt(day)), month: MONTHS[parseInt(month) - 1], year }
  }, [dateValue])

  // Load Anton + Edosz fonts
  useEffect(() => {
    Promise.all([
      new FontFace('Anton', 'url(/anton.ttf)').load(),
      new FontFace('Edosz', 'url(/edosz.ttf)').load(),
      new FontFace('Granesta', 'url(/Granesta.ttf)').load(),
    ]).then(fonts => {
      fonts.forEach(f => document.fonts.add(f))
    }).catch(() => {}).finally(() => setFontReady(true))
  }, [])

  // Load template overlay images once
  useEffect(() => {
    const loadOverlays = async () => {
      const result: { logo?: HTMLImageElement; footer?: HTMLImageElement; brushStroke?: HTMLImageElement } = {}
      if (TEMPLATE.logo) result.logo = await loadImage(TEMPLATE.logo)
      if (TEMPLATE.footer) result.footer = await loadImage(TEMPLATE.footer)
      if (TEMPLATE.brushStroke) result.brushStroke = await loadImage(TEMPLATE.brushStroke)
      setOverlays(result)
    }
    loadOverlays()
  }, [])

  // Redraw canvas whenever inputs change
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    drawCanvas(canvas, TEMPLATE, userPhoto, photoOffset, overlays, parsedDate)
  }, [userPhoto, photoOffset, overlays, parsedDate, fontReady])

  const handleFileChange = useCallback(async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    const url = URL.createObjectURL(file)
    const img = await loadImage(url)
    URL.revokeObjectURL(url)
    setUserPhoto(img)
    setPhotoOffset({ x: 0, y: 0 })
  }, [])

  const toCanvasCoords = useCallback((clientX: number, clientY: number) => {
    const canvas = canvasRef.current!
    const rect = canvas.getBoundingClientRect()
    const scaleX = canvas.width / rect.width
    const scaleY = canvas.height / rect.height
    return { x: (clientX - rect.left) * scaleX, y: (clientY - rect.top) * scaleY }
  }, [])

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const handler = (e: TouchEvent) => {
      e.preventDefault()
      if (!dragStart.current) return
      const t = e.touches[0]
      const pos = toCanvasCoords(t.clientX, t.clientY)
      const dx = pos.x - dragStart.current.x
      const dy = pos.y - dragStart.current.y
      setPhotoOffset({ x: dragStart.current!.ox + dx, y: dragStart.current!.oy + dy })
    }
    canvas.addEventListener('touchmove', handler, { passive: false })
    return () => canvas.removeEventListener('touchmove', handler)
  }, [toCanvasCoords])

  const onMouseDown = useCallback((e: React.MouseEvent) => {
    if (!userPhoto) return
    const pos = toCanvasCoords(e.clientX, e.clientY)
    dragStart.current = { x: pos.x, y: pos.y, ox: photoOffset.x, oy: photoOffset.y }
    setIsDragging(true)
  }, [userPhoto, photoOffset, toCanvasCoords])

  const onMouseMove = useCallback((e: React.MouseEvent) => {
    if (!dragStart.current) return
    const pos = toCanvasCoords(e.clientX, e.clientY)
    const dx = pos.x - dragStart.current.x
    const dy = pos.y - dragStart.current.y
    setPhotoOffset({ x: dragStart.current.ox + dx, y: dragStart.current.oy + dy })
  }, [toCanvasCoords])

  const onMouseUp = useCallback(() => {
    dragStart.current = null
    setIsDragging(false)
  }, [])

  const onTouchStart = useCallback((e: React.TouchEvent) => {
    if (!userPhoto) return
    const t = e.touches[0]
    const pos = toCanvasCoords(t.clientX, t.clientY)
    dragStart.current = { x: pos.x, y: pos.y, ox: photoOffset.x, oy: photoOffset.y }
    setIsDragging(true)
  }, [userPhoto, photoOffset, toCanvasCoords])

  const onTouchEnd = useCallback(() => {
    dragStart.current = null
    setIsDragging(false)
  }, [])

  const handleDownload = useCallback(() => {
    const canvas = canvasRef.current
    if (!canvas || !userPhoto) return
    canvas.toBlob((blob) => {
      if (!blob) return
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = 'majadu-post.png'
      a.click()
      URL.revokeObjectURL(url)
    }, 'image/png')
  }, [userPhoto])

  return (
    <div className="flex flex-col gap-6 pt-4 pb-10">
      {/* Page header */}
      <div className="flex items-center gap-3">
        <button
          onClick={() => navigate('/')}
          className="text-slate-500 hover:text-slate-300 transition-colors text-lg leading-none"
        >
          ←
        </button>
        <div>
          <p className="text-[10px] font-mono text-slate-500 tracking-[0.2em] uppercase">Create</p>
          <h2 className="text-xl font-bold text-yellow-400 tracking-tight leading-none">Instagram Post</h2>
        </div>
      </div>

      {/* Canvas preview */}
      <div className="w-full">
        <canvas
          ref={canvasRef}
          width={TEMPLATE.width}
          height={TEMPLATE.height}
          className={`w-full rounded-xl border border-slate-800 ${userPhoto ? (isDragging ? 'cursor-grabbing' : 'cursor-grab') : 'cursor-default'}`}
          onMouseDown={onMouseDown}
          onMouseMove={onMouseMove}
          onMouseUp={onMouseUp}
          onMouseLeave={onMouseUp}
          onTouchStart={onTouchStart}
          onTouchEnd={onTouchEnd}
        />
      </div>

      {/* Date picker */}
      <div className="flex flex-col gap-1.5">
        <p className="text-[10px] font-mono text-slate-500 tracking-[0.2em] uppercase">Session Date</p>
        <input
          type="date"
          value={dateValue}
          onChange={e => setDateValue(e.target.value)}
          className="bg-slate-900 border border-slate-700 rounded-lg px-4 py-2.5 text-sm text-white w-full"
        />
      </div>

      {/* Upload */}
      <div className="flex items-center gap-3">
        <button
          onClick={() => fileInputRef.current?.click()}
          className="flex items-center gap-2 bg-slate-800 hover:bg-slate-700 border border-slate-700 rounded-lg px-4 py-2.5 text-sm text-slate-300 transition-colors"
        >
          <span>📷</span>
          <span>{userPhoto ? 'Change photo' : 'Upload photo'}</span>
        </button>
        {userPhoto && <span className="text-xs text-slate-500 font-mono">drag canvas to reposition</span>}
        <input
          ref={fileInputRef}
          type="file"
          accept="image/jpeg,image/png,image/webp"
          className="hidden"
          onChange={handleFileChange}
        />
      </div>

      {/* Download */}
      <button
        onClick={handleDownload}
        disabled={!userPhoto}
        className="w-full bg-yellow-400 text-black font-bold text-sm py-3.5 rounded-xl disabled:opacity-30 disabled:cursor-not-allowed hover:bg-yellow-300 transition-colors"
      >
        ⬇ Download (1080 × 1350)
      </button>
      {!userPhoto && (
        <p className="text-center text-xs text-slate-600 -mt-4">Upload a photo to enable download</p>
      )}
    </div>
  )
}
