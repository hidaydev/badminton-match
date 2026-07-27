// src/pages/InstagramPostPage.tsx
import { useRef, useState, useEffect, useCallback, useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { instagramTemplates } from '../config/instagramTemplates'
import { useListSessions, useFetchSession } from '../queries'
import { computeStandings } from '../utils/standings'
import type { SessionMeta } from '../queries'
import { loadImage, drawPostCanvas, drawStandingsCanvas, type OverlayImages } from '../utils/canvasPost'
import { loadOverlayImages } from '../utils/overlays'

const TEMPLATE = instagramTemplates[0]

const MONTHS = ['JAN','FEB','MAR','APR','MEI','JUN','JUL','AGU','SEP','OKT','NOV','DES']


type StandingMode = 'post' | 'story'

export default function InstagramPostPage() {
  const navigate = useNavigate()
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)

  const [userPhoto, setUserPhoto] = useState<HTMLImageElement | null>(null)
  const [photoOffset, setPhotoOffset] = useState({ x: 0, y: 0 })
  const [photoZoom, setPhotoZoom] = useState(1)
  const [overlays, setOverlays] = useState<OverlayImages>({})
  const [isDragging, setIsDragging] = useState(false)
  const [fontReady, setFontReady] = useState(false) // true once browser fonts are loaded
  const [dateValue, setDateValue] = useState(() => new Date().toISOString().split('T')[0])
  const [exportError, setExportError] = useState<string | null>(null)
  const [overlayError, setOverlayError] = useState<string | null>(null)
  const dragStart = useRef<{ x: number; y: number; ox: number; oy: number } | null>(null)
  const pinchStart = useRef<{ dist: number; zoom: number } | null>(null)
  const rafRef = useRef<number | null>(null)

  const parsedDate = useMemo(() => {
    const [year, month, day] = dateValue.split('-')
    return { day: String(parseInt(day)), month: MONTHS[parseInt(month) - 1], year }
  }, [dateValue])

  // Wait for browser to finish loading the @font-face fonts declared in index.html
  useEffect(() => {
    document.fonts.ready.then(() => setFontReady(true))
  }, [])

  // Load template overlay images once
  useEffect(() => {
    const loadOverlays = async () => {
      try {
        const loaded = await loadOverlayImages({
          logo: TEMPLATE.logo,
          footer: TEMPLATE.footer,
          brushStroke: TEMPLATE.brushStroke,
          chevrons: TEMPLATE.chevrons,
          storyBg: TEMPLATE.storyBg,
        })
        setOverlays(loaded as OverlayImages)
      } catch (err) {
        console.error('Failed to load overlay images', err)
        setOverlayError('Failed to load template images. Some features may not work.')
      }
    }
    loadOverlays()
  }, [])

  // Redraw canvas whenever inputs change
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    drawPostCanvas({ canvas, userPhoto, photoOffset, photoZoom, overlays, date: parsedDate })
  }, [userPhoto, photoOffset, photoZoom, overlays, parsedDate, fontReady])

  const handleFileChange = useCallback(async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    const url = URL.createObjectURL(file)
    try {
      const img = await loadImage(url)
      setUserPhoto(img)
      setPhotoOffset({ x: 0, y: 0 })
      setPhotoZoom(1)
    } catch (err) {
      console.error('Failed to load image', err)
      setExportError('Failed to load image. Please try another file.')
    } finally {
      URL.revokeObjectURL(url)
    }
  }, [])

  const toCanvasCoords = useCallback((clientX: number, clientY: number) => {
    const canvas = canvasRef.current!
    const rect = canvas.getBoundingClientRect()
    const scaleX = canvas.width / rect.width
    const scaleY = canvas.height / rect.height
    return { x: (clientX - rect.left) * scaleX, y: (clientY - rect.top) * scaleY }
  }, [])

  const clampOffset = useCallback((x: number, y: number, img: HTMLImageElement, zoom: number) => {
    const canvas = canvasRef.current!
    const scale = Math.max(canvas.width / img.naturalWidth, canvas.height / img.naturalHeight) * zoom
    const w = img.naturalWidth * scale
    const h = img.naturalHeight * scale
    const maxX = (w - canvas.width) / 2
    const maxY = (h - canvas.height) / 2
    return {
      x: Math.min(maxX, Math.max(-maxX, x)),
      y: Math.min(maxY, Math.max(-maxY, y)),
    }
  }, [])

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const handler = (e: TouchEvent) => {
      e.preventDefault()
      if (e.touches.length === 2 && pinchStart.current && userPhoto) {
        const dx = e.touches[0].clientX - e.touches[1].clientX
        const dy = e.touches[0].clientY - e.touches[1].clientY
        const dist = Math.sqrt(dx * dx + dy * dy)
        const newZoom = Math.max(1, Math.min(4, pinchStart.current.zoom * (dist / pinchStart.current.dist)))
        setPhotoZoom(newZoom)
        setPhotoOffset(prev => clampOffset(prev.x, prev.y, userPhoto, newZoom))
        return
      }
      if (!dragStart.current || !userPhoto) return
      const touch = e.touches[0]
      const pos = toCanvasCoords(touch.clientX, touch.clientY)
      const dx = pos.x - dragStart.current.x
      const dy = pos.y - dragStart.current.y
      if (rafRef.current) cancelAnimationFrame(rafRef.current)
      rafRef.current = requestAnimationFrame(() => {
        setPhotoOffset(clampOffset(dragStart.current!.ox + dx, dragStart.current!.oy + dy, userPhoto, photoZoom))
      })
    }
    canvas.addEventListener('touchmove', handler, { passive: false })
    return () => canvas.removeEventListener('touchmove', handler)
  }, [toCanvasCoords, userPhoto, clampOffset, photoZoom])

  const onMouseDown = useCallback((e: React.MouseEvent) => {
    if (!userPhoto) return
    const pos = toCanvasCoords(e.clientX, e.clientY)
    dragStart.current = { x: pos.x, y: pos.y, ox: photoOffset.x, oy: photoOffset.y }
    setIsDragging(true)
  }, [userPhoto, photoOffset, toCanvasCoords])

  const onMouseMove = useCallback((e: React.MouseEvent) => {
    if (!dragStart.current || !userPhoto) return
    const pos = toCanvasCoords(e.clientX, e.clientY)
    const dx = pos.x - dragStart.current.x
    const dy = pos.y - dragStart.current.y
    if (rafRef.current) cancelAnimationFrame(rafRef.current)
    rafRef.current = requestAnimationFrame(() => {
      setPhotoOffset(clampOffset(dragStart.current!.ox + dx, dragStart.current!.oy + dy, userPhoto, photoZoom))
    })
  }, [toCanvasCoords, userPhoto, clampOffset, photoZoom])

  const onMouseUp = useCallback(() => {
    dragStart.current = null
    setIsDragging(false)
    if (rafRef.current) {
      cancelAnimationFrame(rafRef.current)
      rafRef.current = null
    }
  }, [])

  const onTouchStart = useCallback((e: React.TouchEvent) => {
    if (!userPhoto) return
    if (e.touches.length === 2) {
      const dx = e.touches[0].clientX - e.touches[1].clientX
      const dy = e.touches[0].clientY - e.touches[1].clientY
      pinchStart.current = { dist: Math.sqrt(dx * dx + dy * dy), zoom: photoZoom }
      dragStart.current = null
      return
    }
    const touch = e.touches[0]
    const pos = toCanvasCoords(touch.clientX, touch.clientY)
    dragStart.current = { x: pos.x, y: pos.y, ox: photoOffset.x, oy: photoOffset.y }
    pinchStart.current = null
    setIsDragging(true)
  }, [userPhoto, photoOffset, photoZoom, toCanvasCoords])

  const onTouchEnd = useCallback(() => {
    dragStart.current = null
    pinchStart.current = null
    setIsDragging(false)
    if (rafRef.current) {
      cancelAnimationFrame(rafRef.current)
      rafRef.current = null
    }
  }, [])

  const [showDownloadSheet, setShowDownloadSheet] = useState(false)

  const [sheetScreen, setSheetScreen] = useState<'formats' | 'session-picker'>('formats')
  const [pendingStandingMode, setPendingStandingMode] = useState<StandingMode | null>(null)
  const [isGenerating, setIsGenerating] = useState(false)
  const { data: sessions } = useListSessions({ enabled: sheetScreen === 'session-picker' })
  const fetchSession = useFetchSession()

  const triggerDownload = useCallback((blob: Blob, filename: string) => {
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = filename
    a.click()
    URL.revokeObjectURL(url)
  }, [])

  const closeSheet = useCallback(() => {
    setShowDownloadSheet(false)
    setSheetScreen('formats')
    setPendingStandingMode(null)
    setIsGenerating(false)
  }, [])

  const handleDownloadStanding = useCallback(async (sessionMeta: SessionMeta) => {
    if (!pendingStandingMode) return
    const mode = pendingStandingMode
    setIsGenerating(true)

    try {
      const snapshot = await fetchSession(sessionMeta.id)
      if (!snapshot) return

      const standings = computeStandings(
        snapshot.players.filter(p => !(snapshot.absentPlayers ?? []).includes(p.id)),
        snapshot.schedule,
        snapshot.gameScores,
      )

      const isStory = mode === 'story'
      const W = 1080
      const H = isStory ? 1920 : 1350

      const offscreen = document.createElement('canvas')
      offscreen.width = W
      offscreen.height = H

      drawStandingsCanvas({
        canvas: offscreen,
        standings,
        meta: {
          date: sessionMeta.date,
          title: sessionMeta.title,
          playerCount: sessionMeta.playerCount,
        },
        overlays,
        isStory,
        userPhoto,
        photoOffset,
        photoZoom,
      })

      offscreen.toBlob((blob) => {
        if (!blob) {
          console.error('toBlob returned null for standing export')
          setExportError('Failed to generate image. Please try again.')
          setIsGenerating(false)
          return
        }
        const slug = sessionMeta.date.replace(/-/g, '')
        triggerDownload(blob, `majadu-standing-${isStory ? 'story' : 'post'}-${slug}.jpg`)
        closeSheet()
      }, 'image/jpeg', 0.92)
    } catch (err) {
      console.error('Standing export failed', err)
      setExportError('Failed to export standings. Please try again.')
      setIsGenerating(false)
    }
  }, [pendingStandingMode, fetchSession, overlays, triggerDownload, closeSheet, photoOffset, photoZoom, userPhoto, setExportError, setIsGenerating])

  const handleDownloadPost = useCallback(() => {
    const canvas = canvasRef.current
    if (!canvas || !userPhoto) return
    closeSheet()
    canvas.toBlob((blob) => {
      if (!blob) {
        console.error('toBlob returned null for post download')
        setExportError('Failed to generate image. Please try again.')
        return
      }
      triggerDownload(blob, `majadu-post-${dateValue}.jpg`)
    }, 'image/jpeg', 0.92)
  }, [userPhoto, dateValue, triggerDownload, closeSheet, setExportError])

  const handleDownloadStory = useCallback(() => {
    const postCanvas = canvasRef.current
    if (!postCanvas || !userPhoto) return
    closeSheet()

    const W = 1080, H = 1920
    const offscreen = document.createElement('canvas')
    offscreen.width = W
    offscreen.height = H
    const ctx = offscreen.getContext('2d')!

    // Background
    if (overlays.storyBg) {
      ctx.drawImage(overlays.storyBg, 0, 0, W, H)
    } else {
      ctx.fillStyle = '#F5B400'
      ctx.fillRect(0, 0, W, H)
    }

    // Post canvas centered with padding, rounded corners + shadow
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

    // Clip to rounded rect then draw post
    ctx.save()
    ctx.beginPath()
    ctx.roundRect(pX, pY, pW, pH, radius)
    ctx.clip()
    ctx.drawImage(postCanvas, pX, pY, pW, pH)
    ctx.restore()

    offscreen.toBlob((blob) => {
      if (!blob) {
        console.error('toBlob returned null for story download')
        setExportError('Failed to generate image. Please try again.')
        return
      }
      triggerDownload(blob, `majadu-story-${dateValue}.jpg`)
    }, 'image/jpeg', 0.92)
  }, [userPhoto, overlays, dateValue, triggerDownload, closeSheet, setExportError])

  return (
    <div className="flex flex-col">
      {(exportError || overlayError) && (
        <div className="mx-1 mt-2 rounded-xl border border-red-700 bg-red-950/80 px-3 py-2 text-xs text-red-200 flex items-center justify-between gap-2">
          <span>{exportError || overlayError}</span>
          <button
            onClick={() => { setExportError(null); setOverlayError(null) }}
            className="text-red-400 hover:text-red-200 shrink-0"
          >
            ✕
          </button>
        </div>
      )}
      {/* Compact header */}
      <div className="flex items-center gap-3 px-1 pt-4 pb-3">
        <button
          onClick={() => navigate('/')}
          className="w-9 h-9 flex items-center justify-center rounded-full bg-slate-800 text-slate-300 active:bg-slate-700 transition-colors"
        >
          ←
        </button>
        <div>
          <p
            className="text-[10px] font-mono text-slate-400 uppercase"
            style={{ letterSpacing: '0.2em' }}
          >
            Create
          </p>
          <h2 className="text-lg font-bold text-yellow-400 tracking-tight leading-none">Instagram Post</h2>
        </div>
        <input
          type="date"
          value={dateValue}
          onChange={e => setDateValue(e.target.value)}
          className="ml-auto bg-slate-800/60 border border-slate-700 rounded-xl px-3 py-2 text-sm font-semibold text-white outline-none"
        />
      </div>

      {/* Canvas — full width, no side padding */}
      <div className="relative -mx-4">
        <canvas
          ref={canvasRef}
          width={TEMPLATE.width}
          height={TEMPLATE.height}
          className={`w-full ${userPhoto ? (isDragging ? 'cursor-grabbing' : 'cursor-grab') : 'cursor-default'}`}
          onMouseDown={onMouseDown}
          onMouseMove={onMouseMove}
          onMouseUp={onMouseUp}
          onMouseLeave={onMouseUp}
          onTouchStart={onTouchStart}
          onTouchEnd={onTouchEnd}
        />

        {/* Upload prompt overlay when no photo */}
        {!userPhoto && (
          <button
            onClick={() => fileInputRef.current?.click()}
            className="absolute inset-0 flex flex-col items-center justify-center gap-3 bg-slate-900/60 active:bg-slate-900/70 transition-colors"
          >
            <div className="w-16 h-16 rounded-full bg-slate-800 border-2 border-dashed border-slate-600 flex items-center justify-center text-2xl">
              📷
            </div>
            <span className="text-sm font-semibold text-slate-300">Tap to upload photo</span>
          </button>
        )}


        {/* Swap + Download buttons — top right corner when photo uploaded */}
        {userPhoto && (
          <div className="absolute top-3 right-3 flex gap-2">
            <button
              onClick={() => fileInputRef.current?.click()}
              className="w-9 h-9 rounded-full bg-black/50 flex items-center justify-center active:bg-black/70"
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M21 2v6h-6"/>
                <path d="M3 12a9 9 0 0 1 15-6.7L21 8"/>
                <path d="M3 22v-6h6"/>
                <path d="M21 12a9 9 0 0 1-15 6.7L3 16"/>
              </svg>
            </button>
            <button
              onClick={() => setShowDownloadSheet(true)}
              className="w-9 h-9 rounded-full bg-yellow-400 flex items-center justify-center active:bg-yellow-300"
            >
              <svg xmlns="http://www.w3.org/2000/svg" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="black" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
                <polyline points="7 10 12 15 17 10"/>
                <line x1="12" y1="15" x2="12" y2="3"/>
              </svg>
            </button>
          </div>
        )}
      </div>


      <input
        ref={fileInputRef}
        type="file"
        accept="image/jpeg,image/png,image/webp"
        className="hidden"
        onChange={handleFileChange}
      />

      {/* Download format bottom sheet */}
      {showDownloadSheet && (
        <div
          className="fixed inset-0 z-50 flex items-end"
          onClick={closeSheet}
        >
          <div className="absolute inset-0 bg-black/60" />
          <div
            className="relative w-full bg-slate-900 rounded-t-3xl px-5 pt-5 pb-10"
            style={{ boxShadow: '0 -8px 40px rgba(0,0,0,0.6)' }}
            onClick={e => e.stopPropagation()}
          >
            <div className="w-10 h-1 bg-slate-700 rounded-full mx-auto mb-6" />

            {sheetScreen === 'formats' && (
              <>
                <p className="text-xs font-mono text-slate-400 tracking-widest uppercase mb-4">Download as</p>
                <div className="grid grid-cols-2 gap-3">
                  {/* Photo Post */}
                  <button
                    onClick={handleDownloadPost}
                    className="bg-slate-800 active:bg-slate-700 rounded-2xl p-4 flex flex-col items-center gap-3 border border-slate-700"
                  >
                    <div className="w-12 h-15 rounded-lg bg-slate-700 border border-slate-600" />
                    <div className="text-center">
                      <p className="text-sm font-bold text-white">Post</p>
                      <p className="text-[11px] text-slate-400">1080 × 1350</p>
                    </div>
                  </button>

                  {/* Photo Story */}
                  <button
                    onClick={handleDownloadStory}
                    className="bg-yellow-400 active:bg-yellow-300 rounded-2xl p-4 flex flex-col items-center gap-3"
                  >
                    <div className="w-12 h-15 rounded-lg bg-yellow-300 border border-yellow-500 flex items-center justify-center">
                      <div className="w-7 h-7 rounded bg-yellow-500/40" />
                    </div>
                    <div className="text-center">
                      <p className="text-sm font-bold text-black">Story</p>
                      <p className="text-[11px] text-yellow-800">1080 × 1920</p>
                    </div>
                  </button>

                  {/* Standing Post */}
                  <button
                    onClick={() => { setPendingStandingMode('post'); setSheetScreen('session-picker') }}
                    className="bg-slate-800 active:bg-slate-700 rounded-2xl p-4 flex flex-col items-center gap-3 border border-slate-700"
                  >
                    <div className="w-12 h-15 rounded-lg bg-slate-700 border border-slate-600 flex items-center justify-center">
                      <span className="text-lg">🏆</span>
                    </div>
                    <div className="text-center">
                      <p className="text-sm font-bold text-white">Leaderboard Post</p>
                      <p className="text-[11px] text-slate-400">1080 × 1350</p>
                    </div>
                  </button>

                  {/* Standing Story */}
                  <button
                    onClick={() => { setPendingStandingMode('story'); setSheetScreen('session-picker') }}
                    className="bg-yellow-400 active:bg-yellow-300 rounded-2xl p-4 flex flex-col items-center gap-3"
                  >
                    <div className="w-12 h-15 rounded-lg bg-yellow-300 border border-yellow-500 flex items-center justify-center">
                      <span className="text-lg">🏆</span>
                    </div>
                    <div className="text-center">
                      <p className="text-sm font-bold text-black">Leaderboard Story</p>
                      <p className="text-[11px] text-yellow-800">1080 × 1920</p>
                    </div>
                  </button>
                </div>
              </>
            )}

            {sheetScreen === 'session-picker' && (
              <>
                <div className="flex items-center gap-3 mb-4">
                  <button
                    onClick={() => { setSheetScreen('formats'); setIsGenerating(false) }}
                    className="w-8 h-8 rounded-full bg-slate-800 flex items-center justify-center text-slate-400 text-sm active:bg-slate-700"
                  >
                    ←
                  </button>
                  <p className="text-xs font-mono text-slate-400 tracking-widest uppercase">Pick a session</p>
                </div>

                {isGenerating && (
                  <div className="flex items-center justify-center py-8 gap-3">
                    <div className="w-5 h-5 rounded-full border-2 border-yellow-400 border-t-transparent animate-spin" />
                    <span className="text-sm text-slate-400">Generating…</span>
                  </div>
                )}

                {!isGenerating && (
                  <div className="flex flex-col gap-2 max-h-72 overflow-y-auto">
                    {!sessions && (
                      <p className="text-sm text-slate-400 text-center py-4">Loading sessions…</p>
                    )}
                    {sessions?.length === 0 && (
                      <p className="text-sm text-slate-400 text-center py-4">No sessions found</p>
                    )}
                    {sessions?.map(s => (
                      <button
                        key={s.id}
                        onClick={() => handleDownloadStanding(s)}
                        className="flex items-center gap-3 px-4 py-3 rounded-2xl bg-slate-800 active:bg-slate-700 border border-slate-700 text-left"
                      >
                        <div className="flex-1 min-w-0">
                          <p className="text-sm font-semibold text-white truncate">{s.title}</p>
                          <p className="text-[11px] text-slate-400">{s.date} · {s.playerCount} players</p>
                        </div>
                        <span className="text-slate-400 text-xs">→</span>
                      </button>
                    ))}
                  </div>
                )}
              </>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
