// src/pages/InstagramPostPage.tsx
import { useRef, useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { instagramTemplates, type PostTemplate } from '../config/instagramTemplates'

const TEMPLATE = instagramTemplates[0]

const HEADER_H = 90
const LOGO_H = 28

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

// Draws "MAJADU FUN • MAJADU FUN • MAJADU FUN" with yellow dots
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
  // Gradient: solid dark at top → transparent at bottom
  const grad = ctx.createLinearGradient(0, 0, 0, HEADER_H)
  grad.addColorStop(0, 'rgba(10,10,20,0.92)')
  grad.addColorStop(1, 'rgba(0,0,0,0)')
  ctx.fillStyle = grad
  ctx.fillRect(0, 0, canvasW, HEADER_H)

  const fontSize = 15
  const logoW = logo ? LOGO_H * (logo.naturalWidth / logo.naturalHeight) : 160
  const centerPad = 30
  const sideZoneW = (canvasW - logoW) / 2 - centerPad
  const textY = HEADER_H * 0.42

  // Measure left text total width to right-align it flush to center zone
  ctx.font = `bold ${fontSize}px Arial, sans-serif`
  ctx.letterSpacing = '1.5px'
  const fullText = 'MAJADU FUN  •  MAJADU FUN  •  MAJADU FUN'
  const totalW = ctx.measureText(fullText).width
  const clampedW = Math.min(totalW, sideZoneW)

  // Left side: right-aligned to the center zone edge
  const leftStartX = (canvasW - logoW) / 2 - centerPad - clampedW
  drawSideText(ctx, leftStartX, textY, fontSize)

  // Right side: left-aligned from the center zone edge
  const rightStartX = (canvasW + logoW) / 2 + centerPad
  drawSideText(ctx, rightStartX, textY, fontSize)

  // Center logo
  if (logo) {
    ctx.drawImage(logo, (canvasW - logoW) / 2, 10, logoW, LOGO_H)
  }
}

function drawCanvas(
  canvas: HTMLCanvasElement,
  _template: PostTemplate,
  userPhoto: HTMLImageElement | null,
  photoOffset: { x: number; y: number },
  overlays: { logo?: HTMLImageElement; footer?: HTMLImageElement },
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

  // Layer 2: header band (drawn programmatically)
  drawHeader(ctx, canvas.width, overlays.logo)

  // Layer 3: footer
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
  const [overlays, setOverlays] = useState<{ logo?: HTMLImageElement; footer?: HTMLImageElement }>({})
  const [isDragging, setIsDragging] = useState(false)
  const dragStart = useRef<{ x: number; y: number; ox: number; oy: number } | null>(null)

  // Load template overlay images once
  useEffect(() => {
    const loadOverlays = async () => {
      const result: { logo?: HTMLImageElement; footer?: HTMLImageElement } = {}
      if (TEMPLATE.logo) result.logo = await loadImage(TEMPLATE.logo)
      if (TEMPLATE.footer) result.footer = await loadImage(TEMPLATE.footer)
      setOverlays(result)
    }
    loadOverlays()
  }, [])

  // Redraw canvas whenever inputs change
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    drawCanvas(canvas, TEMPLATE, userPhoto, photoOffset, overlays)
  }, [userPhoto, photoOffset, overlays])

  const handleFileChange = useCallback(async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    const url = URL.createObjectURL(file)
    const img = await loadImage(url)
    URL.revokeObjectURL(url)
    setUserPhoto(img)
    setPhotoOffset({ x: 0, y: 0 })
  }, [])

  // Scale client coords to canvas coords
  const toCanvasCoords = useCallback((clientX: number, clientY: number) => {
    const canvas = canvasRef.current!
    const rect = canvas.getBoundingClientRect()
    const scaleX = canvas.width / rect.width
    const scaleY = canvas.height / rect.height
    return { x: (clientX - rect.left) * scaleX, y: (clientY - rect.top) * scaleY }
  }, [])

  // Attach touchmove as non-passive so e.preventDefault() actually suppresses scroll
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
      {/* Header */}
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
