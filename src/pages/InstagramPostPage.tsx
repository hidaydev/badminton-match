// src/pages/InstagramPostPage.tsx
import { useRef, useState, useEffect, useCallback, useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { instagramTemplates, type PostTemplate } from '../config/instagramTemplates'
import { useListSessions, useFetchSession } from '../queries'
import { computeStandings, type PlayerStanding } from '../utils/standings'
import type { SessionMeta } from '../queries'

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
  ctx.fillText(year, 0, yearSize * 0.22 - 5)
  ctx.restore()
}


function drawCanvas(
  canvas: HTMLCanvasElement,
  _template: PostTemplate,
  userPhoto: HTMLImageElement | null,
  photoOffset: { x: number; y: number },
  photoZoom: number,
  overlays: { logo?: HTMLImageElement; footer?: HTMLImageElement; brushStroke?: HTMLImageElement; chevrons?: HTMLImageElement; storyBg?: HTMLImageElement },
  date: { day: string; month: string; year: string } | null,
) {
  const ctx = canvas.getContext('2d')!
  ctx.clearRect(0, 0, canvas.width, canvas.height)

  // Layer 1: user photo
  if (userPhoto) {
    drawCoverFill(ctx, userPhoto, canvas.width, canvas.height, photoOffset.x, photoOffset.y, photoZoom)
  } else {
    ctx.fillStyle = '#1e293b'
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

type StandingMode = 'post' | 'story'

function drawStandingsCanvas(
  canvas: HTMLCanvasElement,
  standings: PlayerStanding[],
  meta: { date: string; title: string; playerCount: number },
  overlays: { logo?: HTMLImageElement; footer?: HTMLImageElement; storyBg?: HTMLImageElement; chevrons?: HTMLImageElement },
  isStory: boolean,
  userPhoto?: HTMLImageElement | null,
  photoOffset?: { x: number; y: number },
  photoZoom?: number,
) {
  const ctx = canvas.getContext('2d')!
  const W = canvas.width
  const H = canvas.height

  ctx.clearRect(0, 0, W, H)

  if (isStory && overlays.storyBg) {
    ctx.drawImage(overlays.storyBg, 0, 0, W, H)
  } else if (!isStory && userPhoto) {
    drawCoverFill(ctx, userPhoto, W, H, photoOffset?.x ?? 0, photoOffset?.y ?? 0, photoZoom ?? 1)
  } else {
    ctx.fillStyle = '#1e293b'
    ctx.fillRect(0, 0, W, H)
  }

  drawHeader(ctx, W, overlays.logo)

  const FOOTER_H = overlays.footer
    ? W * (overlays.footer.naturalHeight / overlays.footer.naturalWidth)
    : 120
  if (overlays.footer) {
    ctx.drawImage(overlays.footer, 0, H - FOOTER_H, W, FOOTER_H)
  }

  // Chevrons ornament (post only, same position as regular post)
  if (!isStory && overlays.chevrons) {
    const img = overlays.chevrons
    const h = 115
    const w = h * (img.naturalWidth / img.naturalHeight)
    ctx.drawImage(img, W - w - 30, H * 0.3, w, h)
  }

  const HEADER_H_PX = 90
  const CONTENT_TOP = HEADER_H_PX + 30
  const CONTENT_BOT = H - FOOTER_H - 30
  const CONTENT_H = CONTENT_BOT - CONTENT_TOP

  // Dark scrim for post (photo bg needs overlay for readability), dark card for story
  if (!isStory && userPhoto) {
    const cardPadX = 90
    const cardPadY = 30
    ctx.save()
    ctx.fillStyle = 'rgba(6, 10, 20, 0.88)'
    ctx.beginPath()
    ctx.roundRect(cardPadX, CONTENT_TOP + cardPadY, W - cardPadX * 2, CONTENT_H - cardPadY * 2, 32)
    ctx.fill()
    ctx.restore()
  } else if (isStory) {
    const cardPadX = 90
    const cardPadY = 30
    ctx.save()
    ctx.fillStyle = 'rgba(6, 10, 20, 0.88)'
    ctx.beginPath()
    ctx.roundRect(cardPadX, CONTENT_TOP + cardPadY, W - cardPadX * 2, CONTENT_H - cardPadY * 2, 32)
    ctx.fill()
    ctx.restore()
  }

  const innerTop = CONTENT_TOP + 80
  const innerPadX = 150

  ctx.save()
  ctx.font = '26px monospace'
  ctx.fillStyle = '#94a3b8'
  ctx.textAlign = 'left'
  ctx.fillText(meta.title, innerPadX, innerTop)
  ctx.restore()

  ctx.save()
  ctx.font = 'bold 36px Arial, sans-serif'
  ctx.fillStyle = '#facc15'
  ctx.textAlign = 'left'
  ctx.fillText(`TOP 10 OF ${meta.playerCount} PLAYERS`, innerPadX, innerTop + 50)
  ctx.restore()

  const top10 = standings.slice(0, 10)
  const rowsTop = innerTop + 110
  const rowsAvailable = (isStory ? CONTENT_BOT - 80 : CONTENT_BOT) - rowsTop - 20
  const rowH = Math.floor(rowsAvailable / 10)

  const RANK_CX = innerPadX + 30
  const NAME_X = innerPadX + 90
  const W_RIGHT_X = W - innerPadX - 290
  const SEP_CX = W - innerPadX - 265
  const L_LEFT_X = W - innerPadX - 250
  const DIFF_RIGHT_X = W - innerPadX

  const MEDALS = ['🥇', '🥈', '🥉']
  const ROW_FONT_SIZE = Math.min(38, rowH * 0.48)
  const STATS_FONT_SIZE = Math.min(34, rowH * 0.43)

  for (let i = 0; i < top10.length; i++) {
    const s = top10[i]
    const rowY = rowsTop + i * rowH
    const baseline = rowY + rowH * 0.62

    if (i > 0) {
      ctx.save()
      ctx.strokeStyle = 'rgba(255,255,255,0.06)'
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(innerPadX, rowY)
      ctx.lineTo(W - innerPadX, rowY)
      ctx.stroke()
      ctx.restore()
    }

    ctx.save()
    if (i < 3) {
      ctx.font = `${ROW_FONT_SIZE}px Arial`
      ctx.textAlign = 'center'
      ctx.fillText(MEDALS[i], RANK_CX, baseline)
    } else {
      ctx.font = `bold ${ROW_FONT_SIZE * 0.75}px monospace`
      ctx.fillStyle = '#475569'
      ctx.textAlign = 'center'
      ctx.fillText(String(i + 1), RANK_CX, baseline)
    }
    ctx.restore()

    ctx.save()
    ctx.font = `bold ${ROW_FONT_SIZE}px Arial, sans-serif`
    ctx.fillStyle = '#ffffff'
    ctx.textAlign = 'left'
    const maxNameW = W_RIGHT_X - NAME_X - 40
    let name = s.player.name
    while (ctx.measureText(name).width > maxNameW && name.length > 1) {
      name = name.slice(0, -1)
    }
    if (name !== s.player.name) name += '…'
    ctx.fillText(name, NAME_X, baseline)
    ctx.restore()

    ctx.save()
    ctx.font = `bold ${STATS_FONT_SIZE}px monospace`
    ctx.fillStyle = '#facc15'
    ctx.textAlign = 'right'
    ctx.fillText(`${s.wins}W`, W_RIGHT_X, baseline)
    ctx.restore()

    ctx.save()
    ctx.font = `${STATS_FONT_SIZE}px monospace`
    ctx.fillStyle = '#334155'
    ctx.textAlign = 'center'
    ctx.fillText('·', SEP_CX, baseline)
    ctx.restore()

    ctx.save()
    ctx.font = `bold ${STATS_FONT_SIZE}px monospace`
    ctx.fillStyle = '#475569'
    ctx.textAlign = 'left'
    ctx.fillText(`${s.losses}L`, L_LEFT_X, baseline)
    ctx.restore()

    const diff = s.diff
    ctx.save()
    ctx.font = `bold ${STATS_FONT_SIZE}px monospace`
    ctx.fillStyle = diff > 0 ? '#4ade80' : diff < 0 ? '#f87171' : '#475569'
    ctx.textAlign = 'right'
    ctx.fillText(diff > 0 ? `+${diff}` : String(diff), DIFF_RIGHT_X, baseline)
    ctx.restore()
  }
}

export default function InstagramPostPage() {
  const navigate = useNavigate()
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)

  const [userPhoto, setUserPhoto] = useState<HTMLImageElement | null>(null)
  const [photoOffset, setPhotoOffset] = useState({ x: 0, y: 0 })
  const [photoZoom, setPhotoZoom] = useState(1)
  const [overlays, setOverlays] = useState<{ logo?: HTMLImageElement; footer?: HTMLImageElement; brushStroke?: HTMLImageElement; chevrons?: HTMLImageElement; storyBg?: HTMLImageElement }>({})
  const [isDragging, setIsDragging] = useState(false)
  const [fontReady, setFontReady] = useState(false) // true once browser fonts are loaded
  const [dateValue, setDateValue] = useState(() => new Date().toISOString().split('T')[0])
  const dragStart = useRef<{ x: number; y: number; ox: number; oy: number } | null>(null)
  const pinchStart = useRef<{ dist: number; zoom: number } | null>(null)

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
      const result: { logo?: HTMLImageElement; footer?: HTMLImageElement; brushStroke?: HTMLImageElement; chevrons?: HTMLImageElement; storyBg?: HTMLImageElement } = {}
      if (TEMPLATE.logo) result.logo = await loadImage(TEMPLATE.logo)
      if (TEMPLATE.footer) result.footer = await loadImage(TEMPLATE.footer)
      if (TEMPLATE.brushStroke) result.brushStroke = await loadImage(TEMPLATE.brushStroke)
      if (TEMPLATE.chevrons) result.chevrons = await loadImage(TEMPLATE.chevrons)
      if (TEMPLATE.storyBg) result.storyBg = await loadImage(TEMPLATE.storyBg)
      setOverlays(result)
    }
    loadOverlays()
  }, [])

  // Redraw canvas whenever inputs change
  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    drawCanvas(canvas, TEMPLATE, userPhoto, photoOffset, photoZoom, overlays, parsedDate)
  }, [userPhoto, photoOffset, photoZoom, overlays, parsedDate, fontReady])

  const handleFileChange = useCallback(async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    const url = URL.createObjectURL(file)
    const img = await loadImage(url)
    URL.revokeObjectURL(url)
    setUserPhoto(img)
    setPhotoOffset({ x: 0, y: 0 })
    setPhotoZoom(1)
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
      const t = e.touches[0]
      const pos = toCanvasCoords(t.clientX, t.clientY)
      const dx = pos.x - dragStart.current.x
      const dy = pos.y - dragStart.current.y
      setPhotoOffset(clampOffset(dragStart.current!.ox + dx, dragStart.current!.oy + dy, userPhoto, photoZoom))
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
    setPhotoOffset(clampOffset(dragStart.current.ox + dx, dragStart.current.oy + dy, userPhoto, photoZoom))
  }, [toCanvasCoords, userPhoto, clampOffset, photoZoom])

  const onMouseUp = useCallback(() => {
    dragStart.current = null
    setIsDragging(false)
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
    const t = e.touches[0]
    const pos = toCanvasCoords(t.clientX, t.clientY)
    dragStart.current = { x: pos.x, y: pos.y, ox: photoOffset.x, oy: photoOffset.y }
    pinchStart.current = null
    setIsDragging(true)
  }, [userPhoto, photoOffset, photoZoom, toCanvasCoords])

  const onTouchEnd = useCallback(() => {
    dragStart.current = null
    pinchStart.current = null
    setIsDragging(false)
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
        snapshot.players,
        snapshot.schedule,
        snapshot.gameScores,
      )

      const isStory = mode === 'story'
      const W = 1080
      const H = isStory ? 1920 : 1350

      const offscreen = document.createElement('canvas')
      offscreen.width = W
      offscreen.height = H

      drawStandingsCanvas(offscreen, standings, {
        date: sessionMeta.date,
        title: sessionMeta.title,
        playerCount: sessionMeta.playerCount,
      }, overlays, isStory, userPhoto, photoOffset, photoZoom)

      offscreen.toBlob((blob) => {
        if (!blob) {
          setIsGenerating(false)
          return
        }
        const slug = sessionMeta.date.replace(/-/g, '')
        triggerDownload(blob, `majadu-standing-${isStory ? 'story' : 'post'}-${slug}.jpg`)
        closeSheet()
      }, 'image/jpeg', 0.92)
    } catch (err) {
      console.error('Standing export failed', err)
      setIsGenerating(false)
    }
  }, [pendingStandingMode, fetchSession, overlays, triggerDownload, closeSheet])

  const handleDownloadPost = useCallback(() => {
    const canvas = canvasRef.current
    if (!canvas || !userPhoto) return
    closeSheet()
    canvas.toBlob((blob) => {
      if (!blob) return
      triggerDownload(blob, `majadu-post-${dateValue}.jpg`)
    }, 'image/jpeg', 0.92)
  }, [userPhoto, dateValue, triggerDownload, closeSheet])

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
      if (!blob) return
      triggerDownload(blob, `majadu-story-${dateValue}.jpg`)
    }, 'image/jpeg', 0.92)
  }, [userPhoto, overlays, dateValue, triggerDownload, closeSheet])

  return (
    <div className="flex flex-col min-h-screen pb-6">
      {/* Compact header */}
      <div className="flex items-center gap-3 px-1 pt-4 pb-3">
        <button
          onClick={() => navigate('/')}
          className="w-9 h-9 flex items-center justify-center rounded-full bg-slate-800 text-slate-300 active:bg-slate-700 transition-colors"
        >
          ←
        </button>
        <div>
          <p className="text-[10px] font-mono text-slate-500 tracking-[0.2em] uppercase">Create</p>
          <h2 className="text-lg font-bold text-yellow-400 tracking-tight leading-none">Instagram Post</h2>
        </div>
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

      {/* Controls */}
      <div className="flex flex-col gap-3 mt-4 px-1">

        {/* Date */}
        <div className="flex flex-col gap-1.5">
          <p className="text-[10px] font-mono text-slate-500 tracking-widest uppercase">Session Date</p>
          <input
            type="date"
            value={dateValue}
            onChange={e => setDateValue(e.target.value)}
            className="bg-slate-800/60 border border-slate-700 rounded-2xl px-4 py-3.5 text-sm font-semibold text-white w-full outline-none"
          />
        </div>


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
            className="relative w-full bg-slate-900 rounded-t-3xl px-5 pt-5 pb-10 shadow-[0_-8px_40px_rgba(0,0,0,0.6)]"
            onClick={e => e.stopPropagation()}
          >
            <div className="w-10 h-1 bg-slate-700 rounded-full mx-auto mb-6" />

            {sheetScreen === 'formats' && (
              <>
                <p className="text-xs font-mono text-slate-500 tracking-widest uppercase mb-4">Download as</p>
                <div className="grid grid-cols-2 gap-3">
                  {/* Photo Post */}
                  <button
                    onClick={handleDownloadPost}
                    className="bg-slate-800 active:bg-slate-700 rounded-2xl p-4 flex flex-col items-center gap-3 border border-slate-700"
                  >
                    <div className="w-12 h-[60px] rounded-lg bg-slate-700 border border-slate-600" />
                    <div className="text-center">
                      <p className="text-sm font-bold text-white">Post</p>
                      <p className="text-[11px] text-slate-500">1080 × 1350</p>
                    </div>
                  </button>

                  {/* Photo Story */}
                  <button
                    onClick={handleDownloadStory}
                    className="bg-yellow-400 active:bg-yellow-300 rounded-2xl p-4 flex flex-col items-center gap-3"
                  >
                    <div className="w-12 h-[60px] rounded-lg bg-yellow-300 border border-yellow-500 flex items-center justify-center">
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
                    <div className="w-12 h-[60px] rounded-lg bg-slate-700 border border-slate-600 flex items-center justify-center">
                      <span className="text-lg">🏆</span>
                    </div>
                    <div className="text-center">
                      <p className="text-sm font-bold text-white">Standing Post</p>
                      <p className="text-[11px] text-slate-500">1080 × 1350</p>
                    </div>
                  </button>

                  {/* Standing Story */}
                  <button
                    onClick={() => { setPendingStandingMode('story'); setSheetScreen('session-picker') }}
                    className="bg-yellow-400 active:bg-yellow-300 rounded-2xl p-4 flex flex-col items-center gap-3"
                  >
                    <div className="w-12 h-[60px] rounded-lg bg-yellow-300 border border-yellow-500 flex items-center justify-center">
                      <span className="text-lg">🏆</span>
                    </div>
                    <div className="text-center">
                      <p className="text-sm font-bold text-black">Standing Story</p>
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
                  <p className="text-xs font-mono text-slate-500 tracking-widest uppercase">Pick a session</p>
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
                      <p className="text-sm text-slate-500 text-center py-4">Loading sessions…</p>
                    )}
                    {sessions?.length === 0 && (
                      <p className="text-sm text-slate-500 text-center py-4">No sessions found</p>
                    )}
                    {sessions?.map(s => (
                      <button
                        key={s.id}
                        onClick={() => handleDownloadStanding(s)}
                        className="flex items-center gap-3 px-4 py-3 rounded-2xl bg-slate-800 active:bg-slate-700 border border-slate-700 text-left"
                      >
                        <div className="flex-1 min-w-0">
                          <p className="text-sm font-semibold text-white truncate">{s.title}</p>
                          <p className="text-[11px] text-slate-500">{s.date} · {s.playerCount} players</p>
                        </div>
                        <span className="text-slate-600 text-xs">→</span>
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
