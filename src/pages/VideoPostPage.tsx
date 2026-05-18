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
  const fileRef = useRef<File | null>(null)

  const [hasVideo, setHasVideo] = useState(false)
  // overlays state triggers re-render when images load (overlaysRef is used inside RAF loop)
  const [, setOverlays] = useState<Overlays>({})
  const [isExporting, setIsExporting] = useState(false)
  const detectedFpsRef = useRef<number>(30)

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
    const video = videoRef.current
    if (rafRef.current !== null) {
      if (video && 'cancelVideoFrameCallback' in video) {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        ;(video as any).cancelVideoFrameCallback(rafRef.current)
      } else {
        cancelAnimationFrame(rafRef.current)
      }
      rafRef.current = null
    }
  }, [])

  const startRenderLoop = useCallback(() => {
    const canvas = canvasRef.current
    const video = videoRef.current
    if (!canvas || !video) return

    function drawFrame() {
      const ctx = canvas!.getContext('2d')!
      ctx.drawImage(video!, 0, 0, canvas!.width, canvas!.height)
      drawHeader(ctx, canvas!.width, overlaysRef.current.logo)
      if (overlaysRef.current.footer) {
        drawFooter(ctx, canvas!.width, canvas!.height, overlaysRef.current.footer)
      }
    }

    // Use requestVideoFrameCallback when available — fires at video's native fps,
    // not the display refresh rate, reducing unnecessary redraws on mobile.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    if ('requestVideoFrameCallback' in video) {
      const mediaTimes: number[] = []

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      function vfcRender(_now: DOMHighResTimeStamp, metadata: any) {
        drawFrame()
        // Measure actual video fps from first 11 frame timestamps
        if (mediaTimes.length < 11) {
          mediaTimes.push(metadata.mediaTime as number)
          if (mediaTimes.length === 11) {
            const diffs = mediaTimes.slice(1).map((t, i) => t - mediaTimes[i])
            const avg = diffs.reduce((a, b) => a + b, 0) / diffs.length
            if (avg > 0) detectedFpsRef.current = Math.round(1 / avg)
          }
        }
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        rafRef.current = (video as any).requestVideoFrameCallback(vfcRender)
      }
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      rafRef.current = (video as any).requestVideoFrameCallback(vfcRender)
    } else {
      function render() {
        drawFrame()
        rafRef.current = requestAnimationFrame(render)
      }
      render()
    }
  }, [])

  const handleFileChange = useCallback(async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    fileRef.current = file

    const video = videoRef.current!
    const canvas = canvasRef.current!

    stopRenderLoop()

    if (video.src && video.src.startsWith('blob:')) {
      URL.revokeObjectURL(video.src)
    }

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
  useEffect(() => () => {
    stopRenderLoop()
    const video = videoRef.current
    if (video?.src?.startsWith('blob:')) {
      URL.revokeObjectURL(video.src)
    }
  }, [stopRenderLoop])

  function triggerDownload(blob: Blob, filename: string) {
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = filename
    a.click()
    URL.revokeObjectURL(url)
  }

  const handleExport = useCallback(async () => {
    const canvas = canvasRef.current
    const video = videoRef.current
    if (!canvas || !video) return

    setIsExporting(true)

    // Rewind and play from start (unmuted for recording)
    video.loop = false
    video.muted = false
    video.onended = null
    await new Promise<void>(r => {
      if (video.currentTime === 0) { r(); return }
      video.onseeked = () => { video.onseeked = null; r() }
      video.currentTime = 0
    })
    video.play()

    const date = new Date().toISOString().split('T')[0].replace(/-/g, '')
    const filename = `majadu-video-${date}.mp4`

    function finish() {
      video!.loop = true
      video!.muted = true
      setIsExporting(false)
    }

    const detectedFps = detectedFpsRef.current
    // Estimate bitrate from file size + duration.
    // Multiply by 1.5 to compensate for H.264 needing ~2x the bits of HEVC for equivalent quality.
    const totalBitrate = fileRef.current && video.duration
      ? (fileRef.current.size * 8) / video.duration
      : 8_000_000
    const videoBitrate = Math.round(totalBitrate * 1.5)
    const audioBitrate = Math.min(Math.round(totalBitrate * 0.004), 320_000) // audio is tiny vs video

    // ── Path 1: MediaRecorder with video/mp4 (iOS Safari 14.5+) ──────────────
    if (MediaRecorder.isTypeSupported('video/mp4')) {
      const stream = canvas.captureStream(detectedFps)
      try {
        const audioStream = (video as HTMLVideoElement & { captureStream(): MediaStream }).captureStream()
        audioStream.getAudioTracks().forEach(t => stream.addTrack(t))
      } catch { /* audio capture not supported — video only */ }

      const chunks: Blob[] = []
      const recorder = new MediaRecorder(stream, { mimeType: 'video/mp4', videoBitsPerSecond: videoBitrate, audioBitsPerSecond: audioBitrate })
      recorder.ondataavailable = e => { if (e.data.size > 0) chunks.push(e.data) }
      recorder.onstop = () => {
        triggerDownload(new Blob(chunks, { type: 'video/mp4' }), filename)
        finish()
      }
      recorder.onerror = () => finish()
      recorder.start()
      video.onended = () => recorder.stop()
      return
    }

    // ── Path 2: WebCodecs + mp4-muxer (Chrome 94+ / Android) ────────────────
    if (typeof VideoEncoder !== 'undefined') {
      const { Muxer, ArrayBufferTarget } = await import('mp4-muxer')
      const target = new ArrayBufferTarget()
      const muxer = new Muxer({
        target,
        video: { codec: 'avc', width: canvas.width, height: canvas.height },
        audio: { codec: 'aac', sampleRate: 48000, numberOfChannels: 2 },
        firstTimestampBehavior: 'offset',
        fastStart: 'in-memory',
      })

      const videoEncoder = new VideoEncoder({
        output: (chunk, meta) => muxer.addVideoChunk(chunk, meta),
        error: console.error,
      })
      videoEncoder.configure({
        codec: 'avc1.640028', // H.264 High Profile Level 4.0
        width: canvas.width,
        height: canvas.height,
        bitrate: videoBitrate,
        framerate: detectedFps,
      })

      const audioEncoder = new AudioEncoder({
        output: (chunk, meta) => muxer.addAudioChunk(chunk, meta),
        error: console.error,
      })
      audioEncoder.configure({
        codec: 'mp4a.40.2',
        sampleRate: 48000,
        numberOfChannels: 2,
        bitrate: audioBitrate,
      })

      // Capture audio via ScriptProcessorNode
      const audioCtx = new AudioContext({ sampleRate: 48000 })
      const source = audioCtx.createMediaElementSource(video)
      const processor = audioCtx.createScriptProcessor(4096, 2, 2)
      source.connect(processor)
      source.connect(audioCtx.destination)
      processor.connect(audioCtx.destination)

      let audioTimestamp = 0
      processor.onaudioprocess = (e) => {
        const left = e.inputBuffer.getChannelData(0)
        const right = e.inputBuffer.getChannelData(1)
        const planar = new Float32Array(left.length * 2)
        planar.set(left, 0)
        planar.set(right, left.length)
        const audioData = new AudioData({
          format: 'f32-planar',
          sampleRate: 48000,
          numberOfFrames: left.length,
          numberOfChannels: 2,
          timestamp: audioTimestamp,
          data: planar,
        })
        audioEncoder.encode(audioData)
        audioData.close()
        audioTimestamp += Math.round((left.length / 48000) * 1_000_000)
      }

      // Encode frames in RAF loop
      let frameTimestamp = 0
      let frameCount = 0
      const FPS = detectedFps
      const US_PER_FRAME = Math.round(1_000_000 / FPS)
      const isExportingRef = { current: true }

      stopRenderLoop()

      async function exportFrame() {
        if (!isExportingRef.current) return
        const ctx = canvas!.getContext('2d')!
        ctx.drawImage(video!, 0, 0, canvas!.width, canvas!.height)
        drawHeader(ctx, canvas!.width, overlaysRef.current.logo)
        if (overlaysRef.current.footer) {
          drawFooter(ctx, canvas!.width, canvas!.height, overlaysRef.current.footer)
        }

        const bitmap = await createImageBitmap(canvas!)
        const frame = new VideoFrame(bitmap, {
          timestamp: frameTimestamp,
          duration: US_PER_FRAME,
        })
        videoEncoder.encode(frame, { keyFrame: frameCount % (FPS * 2) === 0 })
        frame.close()
        bitmap.close()

        frameTimestamp += US_PER_FRAME
        frameCount++
        rafRef.current = requestAnimationFrame(exportFrame)
      }
      exportFrame()

      video.onended = async () => {
        isExportingRef.current = false
        if (rafRef.current !== null) cancelAnimationFrame(rafRef.current)

        try {
          await videoEncoder.flush()
          await audioEncoder.flush()
          videoEncoder.close()
          audioEncoder.close()
          muxer.finalize()
          const blob = new Blob([target.buffer], { type: 'video/mp4' })
          triggerDownload(blob, filename)
        } catch (err) {
          console.error('Export failed:', err)
        } finally {
          processor.disconnect()
          source.disconnect()
          audioCtx.close()
          startRenderLoop()
          finish()
        }
      }
      return
    }

    // ── Path 3: Fallback — webm ───────────────────────────────────────────────
    const stream = canvas.captureStream(detectedFps)
    try {
      const audioStream = (video as HTMLVideoElement & { captureStream(): MediaStream }).captureStream()
      audioStream.getAudioTracks().forEach(t => stream.addTrack(t))
    } catch { /* audio capture not supported — video only */ }
    const chunks: Blob[] = []
    const recorder = new MediaRecorder(stream, { mimeType: 'video/webm', videoBitsPerSecond: videoBitrate, audioBitsPerSecond: audioBitrate })
    recorder.ondataavailable = e => { if (e.data.size > 0) chunks.push(e.data) }
    recorder.onstop = () => {
      triggerDownload(new Blob(chunks, { type: 'video/webm' }), filename.replace('.mp4', '.webm'))
      finish()
    }
    recorder.onerror = () => finish()
    recorder.start()
    video.onended = () => recorder.stop()
  }, [startRenderLoop, stopRenderLoop])

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
