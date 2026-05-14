// src/pages/InstagramPostPage.tsx
import { useRef, useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { instagramTemplates, type PostTemplate } from '../config/instagramTemplates'

const TEMPLATE = instagramTemplates[0]

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

function drawCanvas(
  canvas: HTMLCanvasElement,
  template: PostTemplate,
  userPhoto: HTMLImageElement | null,
  photoOffset: { x: number; y: number },
  overlayImages: { header?: HTMLImageElement; footer?: HTMLImageElement },
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

  // Layer 2: header
  if (overlayImages.header) {
    const img = overlayImages.header
    const h = canvas.width * (img.naturalHeight / img.naturalWidth)
    ctx.drawImage(img, 0, 0, canvas.width, h)
  }

  // Layer 3: footer
  if (overlayImages.footer) {
    const img = overlayImages.footer
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
  const [overlays, setOverlays] = useState<{ header?: HTMLImageElement; footer?: HTMLImageElement }>({})
  const [isDragging, setIsDragging] = useState(false)
  const dragStart = useRef<{ x: number; y: number; ox: number; oy: number } | null>(null)

  // Load template overlay images once
  useEffect(() => {
    const loadOverlays = async () => {
      const result: { header?: HTMLImageElement; footer?: HTMLImageElement } = {}
      if (TEMPLATE.header) result.header = await loadImage(TEMPLATE.header)
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
  }, [userPhoto, photoOffset, toCanvasCoords])

  const onTouchMove = useCallback((e: React.TouchEvent) => {
    e.preventDefault()
    if (!dragStart.current) return
    const t = e.touches[0]
    const pos = toCanvasCoords(t.clientX, t.clientY)
    const dx = pos.x - dragStart.current.x
    const dy = pos.y - dragStart.current.y
    setPhotoOffset({ x: dragStart.current.ox + dx, y: dragStart.current.oy + dy })
  }, [toCanvasCoords])

  const onTouchEnd = useCallback(() => {
    dragStart.current = null
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
          onTouchMove={onTouchMove}
          onTouchEnd={onTouchEnd}
        />
        {userPhoto && (
          <p className="text-center text-[10px] text-slate-600 mt-1 font-mono">drag to reposition</p>
        )}
      </div>

      {/* Upload */}
      <div className="flex flex-col gap-1.5">
        <p className="text-[10px] font-mono text-slate-500 tracking-[0.2em] uppercase">Photo</p>
        <button
          onClick={() => fileInputRef.current?.click()}
          className="w-full bg-slate-900 border border-dashed border-slate-700 rounded-xl p-6 flex flex-col items-center gap-2 hover:border-slate-500 transition-colors"
        >
          <span className="text-2xl">{userPhoto ? '🔄' : '📷'}</span>
          <span className="text-sm text-slate-400">{userPhoto ? 'Change photo' : 'Tap to upload photo'}</span>
          <span className="text-xs text-slate-600">JPG or PNG</span>
        </button>
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
