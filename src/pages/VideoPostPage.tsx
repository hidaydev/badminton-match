import { useRef, useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { instagramTemplates } from '../config/instagramTemplates'

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

  const logoW = logo ? LOGO_H * (logo.naturalWidth / logo.naturalHeight) : 160
  const logoTop = (HEADER_H - LOGO_H) / 2

  if (logo) {
    ctx.drawImage(logo, (canvasW - logoW) / 2, logoTop, logoW, LOGO_H)
  }
}

function drawFooter(
  ctx: CanvasRenderingContext2D,
  canvasW: number,
  canvasH: number,
  footer: HTMLImageElement,
) {
  const h = canvasW * (footer.naturalHeight / footer.naturalWidth)
  ctx.drawImage(footer, 0, canvasH - h, canvasW, h)
}

type Overlays = { logo?: HTMLImageElement; footer?: HTMLImageElement }

export default function VideoPostPage() {
  const navigate = useNavigate()
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const videoRef = useRef<HTMLVideoElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const rafRef = useRef<number | null>(null)
  const overlaysRef = useRef<Overlays>({})

  const [hasVideo, setHasVideo] = useState(false)
  // overlays state triggers re-render when images load (overlaysRef is used inside RAF loop)
  const [, setOverlays] = useState<Overlays>({})
  const [isExporting] = useState(false)

  // Load template overlay images once
  useEffect(() => {
    async function load() {
      const result: Overlays = {}
      if (TEMPLATE.logo) result.logo = await loadImage(TEMPLATE.logo)
      if (TEMPLATE.footer) result.footer = await loadImage(TEMPLATE.footer)
      overlaysRef.current = result
      setOverlays(result)
    }
    load()
  }, [])

  const stopRenderLoop = useCallback(() => {
    if (rafRef.current !== null) {
      cancelAnimationFrame(rafRef.current)
      rafRef.current = null
    }
  }, [])

  const startRenderLoop = useCallback(() => {
    const canvas = canvasRef.current
    const video = videoRef.current
    if (!canvas || !video) return

    function render() {
      const ctx = canvas!.getContext('2d')!
      ctx.drawImage(video!, 0, 0, canvas!.width, canvas!.height)
      drawHeader(ctx, canvas!.width, overlaysRef.current.logo)
      if (overlaysRef.current.footer) {
        drawFooter(ctx, canvas!.width, canvas!.height, overlaysRef.current.footer)
      }
      rafRef.current = requestAnimationFrame(render)
    }
    render()
  }, [])

  const handleFileChange = useCallback(async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return

    const video = videoRef.current!
    const canvas = canvasRef.current!

    stopRenderLoop()

    const url = URL.createObjectURL(file)
    video.src = url
    video.load()

    await new Promise<void>(resolve => { video.onloadedmetadata = () => resolve() })

    canvas.width = video.videoWidth || 1080
    canvas.height = video.videoHeight || 1920
    video.muted = true
    video.loop = true
    video.play()
    setHasVideo(true)
    startRenderLoop()
  }, [startRenderLoop, stopRenderLoop])

  // Cleanup on unmount
  useEffect(() => () => stopRenderLoop(), [stopRenderLoop])

  // Task 3 will call this — kept here so it doesn't need to be re-added
  // @ts-expect-error reserved for Task 3 export implementation
  function triggerDownload(blob: Blob, filename: string) {
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = filename
    a.click()
    URL.revokeObjectURL(url)
  }

  // Export placeholder — replaced in Task 3
  const handleExport = useCallback(async () => {
    console.log('export not yet implemented')
  }, [])

  return (
    <div className="flex flex-col">
      {/* Header */}
      <div className="flex items-center gap-3 px-1 pt-4 pb-3">
        <button
          onClick={() => navigate('/')}
          className="w-9 h-9 flex items-center justify-center rounded-full bg-slate-800 text-slate-300 active:bg-slate-700 transition-colors"
        >
          ←
        </button>
        <div>
          <p className="text-[10px] font-mono text-slate-500 tracking-[0.2em] uppercase">Create</p>
          <h2 className="text-lg font-bold text-yellow-400 tracking-tight leading-none">Video Post</h2>
        </div>
      </div>

      {/* Canvas — full width, no side padding */}
      <div className="relative -mx-4">
        <canvas
          ref={canvasRef}
          width={1080}
          height={1920}
          className="w-full"
        />

        {/* Upload overlay — shown when no video */}
        {!hasVideo && (
          <button
            onClick={() => fileInputRef.current?.click()}
            className="absolute inset-0 flex flex-col items-center justify-center gap-3 bg-slate-900/60 active:bg-slate-900/70 transition-colors"
          >
            <div className="w-16 h-16 rounded-full bg-slate-800 border-2 border-dashed border-slate-600 flex items-center justify-center text-2xl">
              🎥
            </div>
            <span className="text-sm font-semibold text-slate-300">Tap to upload video</span>
          </button>
        )}

        {/* Icon buttons — top-right, shown when video loaded */}
        {hasVideo && (
          <div className="absolute top-3 right-3 flex gap-2">
            {/* Swap */}
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
            {/* Export */}
            <button
              onClick={handleExport}
              disabled={isExporting}
              className="w-9 h-9 rounded-full bg-yellow-400 flex items-center justify-center active:bg-yellow-300 disabled:opacity-60"
            >
              {isExporting ? (
                <span className="w-4 h-4 border-2 border-black border-t-transparent rounded-full animate-spin" />
              ) : (
                <svg xmlns="http://www.w3.org/2000/svg" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="black" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/>
                  <polyline points="7 10 12 15 17 10"/>
                  <line x1="12" y1="15" x2="12" y2="3"/>
                </svg>
              )}
            </button>
          </div>
        )}
      </div>

      <video ref={videoRef} className="hidden" playsInline />
      <input
        ref={fileInputRef}
        type="file"
        accept="video/*"
        className="hidden"
        onChange={handleFileChange}
      />
    </div>
  )
}
