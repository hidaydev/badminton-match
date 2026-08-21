// src/pages/TeamTournamentSharePage.tsx
// Dedicated share page untuk team tournament standings.
// Reuse canvas utilities dari canvasPost.ts + photo upload/drag/zoom UX.

import { useRef, useState, useEffect, useCallback, useMemo } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useGetTournament } from '../queries'
import { computeTeamStandings, type TeamTournamentSnapshot, type TeamStandingRow } from '../utils/teamTournament'
import { loadImage, type OverlayImages } from '../utils/canvasPost'
import { loadOverlayImages } from '../utils/overlays'
import { canvasToBlob, shareOrDownload } from '../utils/share'
import { tournamentTemplate } from '../config/tournamentTemplates'

const TEMPLATE = tournamentTemplate

export default function TeamTournamentSharePage() {
  const { id = '' } = useParams()
  const navigate = useNavigate()
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)

  const { data, isFetching } = useGetTournament(id)
  const snap = data && data.format === 'team' ? data : null
  const standings = useMemo(
    () => (snap ? computeTeamStandings(snap.teams, snap.matches) : []),
    [snap],
  )

  const [userPhoto, setUserPhoto] = useState<HTMLImageElement | null>(null)
  const [photoOffset, setPhotoOffset] = useState({ x: 0, y: 0 })
  const [photoZoom, setPhotoZoom] = useState(1)
  const [overlays, setOverlays] = useState<OverlayImages>({})
  const [isDragging, setIsDragging] = useState(false)
  const [fontReady, setFontReady] = useState(false)
  const [exporting, setExporting] = useState(false)
  const dragStart = useRef<{ x: number; y: number; ox: number; oy: number } | null>(null)
  const pinchStart = useRef<{ dist: number; zoom: number } | null>(null)
  const rafRef = useRef<number | null>(null)

  // Wait for fonts
  useEffect(() => {
    document.fonts.ready.then(() => setFontReady(true))
  }, [])

  // Load overlays
  useEffect(() => {
    loadOverlayImages({
      logo: TEMPLATE.logo,
      sponsor: TEMPLATE.sponsor,
    }).then((loaded) => setOverlays(loaded as OverlayImages))
      .catch(console.error)
  }, [])

  // Canvas redraw
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas || !snap) return
    drawTeamStandingsCanvas({
      canvas,
      snap,
      standings,
      userPhoto,
      photoOffset,
      photoZoom,
      overlays,
    })
  }, [snap, standings, userPhoto, photoOffset, photoZoom, overlays, fontReady])

  // Photo load
  const handleFileChange = useCallback(async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    const url = URL.createObjectURL(file)
    try {
      const img = await loadImage(url)
      setUserPhoto(img)
      setPhotoOffset({ x: 0, y: 0 })
      setPhotoZoom(1)
    } catch {
      console.error('Failed to load image')
    } finally {
      URL.revokeObjectURL(url)
    }
  }, [])

  // Canvas coord helper
  const toCanvasCoords = useCallback((clientX: number, clientY: number) => {
    const canvas = canvasRef.current!
    const rect = canvas.getBoundingClientRect()
    return {
      x: (clientX - rect.left) * (canvas.width / rect.width),
      y: (clientY - rect.top) * (canvas.height / rect.height),
    }
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

  // Touch/mouse handlers (same as InstagramPostPage)
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
        setPhotoOffset((prev) => clampOffset(prev.x, prev.y, userPhoto, newZoom))
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
    if (rafRef.current) { cancelAnimationFrame(rafRef.current); rafRef.current = null }
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
    if (rafRef.current) { cancelAnimationFrame(rafRef.current); rafRef.current = null }
  }, [])

  // Export
  const handleExport = useCallback(async () => {
    const canvas = canvasRef.current
    if (!canvas || !snap) return
    setExporting(true)
    try {
      const blob = await canvasToBlob(canvas, 0.95)
      if (blob) {
        const file = new File([blob], `${snap.name.replace(/\s+/g, '_')}_standings.jpg`, { type: 'image/jpeg' })
        await shareOrDownload([file], `${snap.name} Standings`)
      }
    } finally {
      setExporting(false)
    }
  }, [snap])

  if (!snap) {
    return <p className="text-fg-dim text-sm p-4">{isFetching ? 'Loading…' : 'Tournament not found.'}</p>
  }

  return (
    <div className="flex flex-col min-h-screen bg-black">
      {/* Header */}
      <div className="flex items-center justify-between px-4 py-3 bg-surface border-b border-border-subtle">
        <button onClick={() => navigate(-1)} className="text-sm text-fg-dim hover:text-fg">
          ← Back
        </button>
        <span className="text-sm font-semibold text-fg truncate">{snap.name}</span>
        <div className="w-12" />
      </div>

      {/* Canvas preview */}
      <div className="flex-1 flex items-center justify-center p-4 overflow-hidden">
        <div className="relative max-w-sm w-full">
          <canvas
            ref={canvasRef}
            width={TEMPLATE.width}
            height={TEMPLATE.height}
            className={`w-full h-auto rounded-lg ${isDragging ? 'cursor-grabbing' : userPhoto ? 'cursor-grab' : ''}`}
            onMouseDown={onMouseDown}
            onMouseMove={onMouseMove}
            onMouseUp={onMouseUp}
            onMouseLeave={onMouseUp}
            onTouchStart={onTouchStart}
            onTouchEnd={onTouchEnd}
          />

          {/* Upload button (when no photo) */}
          {!userPhoto && (
            <button
              onClick={() => fileInputRef.current?.click()}
              className="absolute inset-0 flex flex-col items-center justify-center gap-2 rounded-lg bg-black/30 hover:bg-black/40 transition-colors"
            >
              <div className="w-14 h-14 rounded-full bg-white/20 flex items-center justify-center">
                <span className="text-2xl">📷</span>
              </div>
              <span className="text-sm font-semibold text-white">Tap to upload photo</span>
            </button>
          )}

          {/* Photo controls (when photo uploaded) */}
          {userPhoto && (
            <div className="absolute top-3 right-3 flex gap-2">
              <button
                onClick={() => fileInputRef.current?.click()}
                className="w-9 h-9 rounded-full bg-black/50 flex items-center justify-center active:bg-black/70"
              >
                <svg xmlns="http://www.w3.org/2000/svg" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M21 2v6h-6" /><path d="M3 12a9 9 0 0 1 15-6.7L21 8" />
                  <path d="M3 22v-6h6" /><path d="M21 12a9 9 0 0 1-15 6.7L3 16" />
                </svg>
              </button>
              <button
                onClick={() => { setUserPhoto(null); setPhotoOffset({ x: 0, y: 0 }); setPhotoZoom(1) }}
                className="w-9 h-9 rounded-full bg-black/50 flex items-center justify-center active:bg-black/70"
              >
                <span className="text-white text-sm">✕</span>
              </button>
            </div>
          )}
        </div>
      </div>

      {/* Bottom actions */}
      <div className="px-4 py-4 bg-surface border-t border-border-subtle flex gap-3">
        <button
          onClick={() => fileInputRef.current?.click()}
          className="flex-1 py-3 rounded-lg border border-border-subtle text-fg-dim font-semibold text-sm hover:text-fg hover:border-border transition-colors"
        >
          📷 Foto
        </button>
        <button
          onClick={handleExport}
          disabled={exporting}
          className="flex-1 py-3 rounded-lg bg-accent text-slate-950 font-bold text-sm disabled:opacity-40"
        >
          {exporting ? 'Exporting…' : '📤 Share'}
        </button>
      </div>

      <input
        ref={fileInputRef}
        type="file"
        accept="image/jpeg,image/png,image/webp"
        className="hidden"
        onChange={handleFileChange}
      />
    </div>
  )
}

// ── Canvas drawing ─────────────────────────────────────────────────────────

const W = 1080
const H = 1350
const PAD = 50
const ACCENT = '#6366f1'
const TEXT_FG = '#f8fafc'
const TEXT_DIM = '#94a3b8'

function drawCoverFill(
  ctx: CanvasRenderingContext2D,
  img: HTMLImageElement,
  canvasW: number,
  canvasH: number,
  offsetX: number,
  offsetY: number,
  zoom: number = 1,
) {
  if (!img.naturalWidth || !img.naturalHeight) return
  const scale = Math.max(canvasW / img.naturalWidth, canvasH / img.naturalHeight) * zoom
  const w = img.naturalWidth * scale
  const h = img.naturalHeight * scale
  const x = (canvasW - w) / 2 + offsetX
  const y = (canvasH - h) / 2 + offsetY
  ctx.drawImage(img, x, y, w, h)
}

function truncateToWidth(ctx: CanvasRenderingContext2D, text: string, maxWidth: number): string {
  let t = text
  while (ctx.measureText(t + '…').width > maxWidth && t.length > 1) t = t.slice(0, -1)
  return t !== text ? t + '…' : t
}

function drawTeamStandingsCanvas({
  canvas,
  snap,
  standings,
  userPhoto,
  photoOffset,
  photoZoom,
  overlays,
}: {
  canvas: HTMLCanvasElement
  snap: TeamTournamentSnapshot
  standings: TeamStandingRow[]
  userPhoto: HTMLImageElement | null
  photoOffset: { x: number; y: number }
  photoZoom: number
  overlays: OverlayImages
}) {
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, W, H)

  // Background
  if (userPhoto) {
    drawCoverFill(ctx, userPhoto, W, H, photoOffset.x, photoOffset.y, photoZoom)
    ctx.fillStyle = 'rgba(15, 23, 42, 0.72)'
    ctx.fillRect(0, 0, W, H)
  } else {
    const grad = ctx.createLinearGradient(0, 0, 0, H)
    grad.addColorStop(0, '#0f172a')
    grad.addColorStop(0.5, '#1e293b')
    grad.addColorStop(1, '#0f172a')
    ctx.fillStyle = grad
    ctx.fillRect(0, 0, W, H)
  }

  // Decorative border
  ctx.strokeStyle = ACCENT
  ctx.lineWidth = 3
  ctx.beginPath()
  ctx.roundRect(PAD / 2, PAD / 2, W - PAD, H - PAD, 16)
  ctx.stroke()
  ctx.strokeStyle = 'rgba(99, 102, 241, 0.2)'
  ctx.lineWidth = 1
  ctx.beginPath()
  ctx.roundRect(PAD, PAD, W - PAD * 2, H - PAD * 2, 12)
  ctx.stroke()

  let y = PAD + 60

  // Title
  ctx.fillStyle = TEXT_FG
  ctx.font = 'bold 44px "IBM Plex Sans", Arial, sans-serif'
  ctx.textAlign = 'center'
  ctx.fillText(snap.name, W / 2, y)
  y += 45

  // Subtitle
  ctx.fillStyle = TEXT_DIM
  ctx.font = '20px "IBM Plex Sans", Arial, sans-serif'
  ctx.fillText(`${snap.date} · ${snap.teams.length} teams`, W / 2, y)
  y += 40

  // Accent line
  ctx.strokeStyle = ACCENT
  ctx.lineWidth = 2
  ctx.beginPath()
  ctx.moveTo((W - 200) / 2, y)
  ctx.lineTo((W + 200) / 2, y)
  ctx.stroke()
  y += 30

  // Champion announcement
  const championTeam = standings[0] ? snap.teams.find((t) => t.id === standings[0].teamId) : null
  if (championTeam) {
    ctx.fillStyle = 'rgba(99, 102, 241, 0.12)'
    ctx.beginPath()
    ctx.roundRect(PAD + 30, y, W - PAD * 2 - 60, 80, 10)
    ctx.fill()
    ctx.strokeStyle = ACCENT
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.roundRect(PAD + 30, y, W - PAD * 2 - 60, 80, 10)
    ctx.stroke()

    ctx.fillStyle = ACCENT
    ctx.font = '14px "IBM Plex Mono", monospace'
    ctx.textAlign = 'center'
    ctx.fillText('🏆 CHAMPION', W / 2, y + 25)
    ctx.fillStyle = TEXT_FG
    ctx.font = 'bold 28px "IBM Plex Sans", Arial, sans-serif'
    ctx.fillText(championTeam.name, W / 2, y + 58)
    y += 100
  }

  // Standings rows
  const medals = ['👑', '🥈', '🥉']
  for (let i = 0; i < standings.length; i++) {
    const r = standings[i]
    const team = snap.teams.find((t) => t.id === r.teamId)
    const rowY = y + i * 70

    if (i === 0) {
      ctx.fillStyle = 'rgba(99, 102, 241, 0.08)'
      ctx.beginPath()
      ctx.roundRect(PAD + 20, rowY, W - PAD * 2 - 40, 62, 8)
      ctx.fill()
    }

    // Rank
    ctx.fillStyle = i === 0 ? ACCENT : TEXT_DIM
    ctx.font = i < 3 ? '24px Arial' : 'bold 20px "IBM Plex Mono", monospace'
    ctx.textAlign = 'left'
    ctx.fillText(i < 3 ? medals[i] : `${i + 1}`, PAD + 40, rowY + 32)

    // Team name
    ctx.fillStyle = i === 0 ? ACCENT : TEXT_FG
    ctx.font = 'bold 22px "IBM Plex Sans", Arial, sans-serif'
    ctx.fillText(r.teamName, PAD + 80, rowY + 32)

    // Stats
    ctx.fillStyle = TEXT_DIM
    ctx.font = '18px "IBM Plex Mono", monospace'
    ctx.textAlign = 'right'
    ctx.fillText(`${r.points}pt · ${r.teamWins}-${r.teamLosses}`, W - PAD - 40, rowY + 32)

    // Members
    if (team && team.players.length > 0) {
      ctx.fillStyle = TEXT_DIM
      ctx.font = '13px "IBM Plex Mono", monospace'
      ctx.textAlign = 'left'
      const members = team.players.map((p) => `${p.cls} ${p.name}`).join('  ·  ')
      ctx.fillText(truncateToWidth(ctx, members, W - PAD * 2 - 200), PAD + 80, rowY + 52)
    }
  }

  y += standings.length * 70 + 30

  // Footer
  ctx.strokeStyle = ACCENT
  ctx.lineWidth = 1
  ctx.beginPath()
  ctx.moveTo(PAD + 40, y)
  ctx.lineTo(W - PAD - 40, y)
  ctx.stroke()
  y += 25

  // Logo
  if (overlays.logo) {
    const logoH = 24
    const logoW = logoH * (overlays.logo.naturalWidth / overlays.logo.naturalHeight)
    ctx.drawImage(overlays.logo, (W - logoW) / 2, y, logoW, logoH)
  }
}
