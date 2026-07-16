import { useState, useCallback, useEffect, useRef } from 'react'
import { useNavigate } from 'react-router-dom'

const LS_RED = 'score-red'
const LS_BLUE = 'score-blue'

function readLS(key: string) {
  const v = localStorage.getItem(key)
  if (v === null) return 0
  const parsed = parseInt(v, 10)
  return Number.isFinite(parsed) ? parsed : 0
}

async function enterFullscreenLandscape(): Promise<string | null> {
  if (!document.fullscreenEnabled) return 'Fullscreen not supported on this browser'
  try {
    await document.documentElement.requestFullscreen()
  } catch (e) {
    return `Fullscreen failed: ${e instanceof Error ? e.message : String(e)}`
  }
  try {
    await screen.orientation.lock('landscape')
  } catch (_error) {
    void _error
  }
  return null
}

async function exitFullscreen() {
  try {
    if (document.fullscreenElement) await document.exitFullscreen()
  } catch (_error) {
    void _error
  }
}

export interface OverlayConfig {
  matchId: string
  pairAName: string
  pairBName: string
  initialScoreA: number
  initialScoreB: number
  onSave: (scoreA: number, scoreB: number) => Promise<void>
  onClose: () => void
}

export default function ScoreboardPage({ overlay }: { overlay?: OverlayConfig } = {}) {
  const navigate = useNavigate()

  const [red, setRed] = useState(() => overlay ? overlay.initialScoreA : readLS(LS_RED))
  const [blue, setBlue] = useState(() => overlay ? overlay.initialScoreB : readLS(LS_BLUE))
  const [redName, setRedName] = useState(() => {
    if (overlay) return overlay.pairAName
    const v = localStorage.getItem('name-red')
    return (v === 'Red' || v === null) ? '' : v
  })
  const [blueName, setBlueName] = useState(() => {
    if (overlay) return overlay.pairBName
    const v = localStorage.getItem('name-blue')
    return (v === 'Blue' || v === null) ? '' : v
  })
  const [editingRed, setEditingRed] = useState(false)
  const [editingBlue, setEditingBlue] = useState(false)
  const [popRed, setPopRed] = useState(false)
  const [popBlue, setPopBlue] = useState(false)
  const [isSwapped, setIsSwapped] = useState(false)
  const [isFullscreen, setIsFullscreen] = useState(() => !!document.fullscreenElement)
  const [fsError, setFsError] = useState<string | null>(null)
  const [isPortrait, setIsPortrait] = useState(() => window.innerWidth < window.innerHeight)
  const [pendingClose, setPendingClose] = useState(false)
  const [isSaving, setIsSaving] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)

  const initialRed = useRef<number | null>(null)
  const initialBlue = useRef<number | null>(null)
  if (overlay) {
    if (initialRed.current === null) initialRed.current = overlay.initialScoreA
    if (initialBlue.current === null) initialBlue.current = overlay.initialScoreB
  }

  const redTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const blueTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const fsErrorTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => { if (!overlay) localStorage.setItem(LS_RED, String(red)) }, [red, overlay])
  useEffect(() => { if (!overlay) localStorage.setItem(LS_BLUE, String(blue)) }, [blue, overlay])
  useEffect(() => { if (!overlay) localStorage.setItem('name-red', redName) }, [redName, overlay])
  useEffect(() => { if (!overlay) localStorage.setItem('name-blue', blueName) }, [blueName, overlay])

  useEffect(() => {
    const onChange = () => setIsFullscreen(!!document.fullscreenElement)
    document.addEventListener('fullscreenchange', onChange)
    const onResize = () => setIsPortrait(window.innerWidth < window.innerHeight)
    window.addEventListener('resize', onResize)
    return () => {
      document.removeEventListener('fullscreenchange', onChange)
      window.removeEventListener('resize', onResize)
      if (redTimer.current) clearTimeout(redTimer.current)
      if (blueTimer.current) clearTimeout(blueTimer.current)
    }
  }, [])

  function triggerPop(side: 'red' | 'blue') {
    if (side === 'red') {
      setPopRed(true)
      if (redTimer.current) clearTimeout(redTimer.current)
      redTimer.current = setTimeout(() => setPopRed(false), 180)
    } else {
      setPopBlue(true)
      if (blueTimer.current) clearTimeout(blueTimer.current)
      blueTimer.current = setTimeout(() => setPopBlue(false), 180)
    }
  }

  const addRed = useCallback(() => { if (isSaving) return; setRed(r => r + 1); triggerPop('red') }, [isSaving])
  const addBlue = useCallback(() => { if (isSaving) return; setBlue(b => b + 1); triggerPop('blue') }, [isSaving])

  const minusRed = useCallback((e: React.MouseEvent) => {
    e.stopPropagation()
    if (isSaving) return
    setRed(r => Math.max(0, r - 1))
    triggerPop('red')
  }, [isSaving])

  const minusBlue = useCallback((e: React.MouseEvent) => {
    e.stopPropagation()
    if (isSaving) return
    setBlue(b => Math.max(0, b - 1))
    triggerPop('blue')
  }, [isSaving])

  const reset = useCallback(() => { setRed(0); setBlue(0) }, [])

  const toggleFullscreen = useCallback(async () => {
    if (isFullscreen) { exitFullscreen(); return }
    const err = await enterFullscreenLandscape()
    if (err) {
      setFsError(err)
      if (fsErrorTimer.current) clearTimeout(fsErrorTimer.current)
      fsErrorTimer.current = setTimeout(() => setFsError(null), 4000)
    }
  }, [isFullscreen])

  const doSwap = useCallback(() => {
    setIsSwapped(s => !s)
  }, [])

  const handleOverlayClose = useCallback(() => {
    if (!overlay) return
    if (red !== (initialRed.current ?? 0) || blue !== (initialBlue.current ?? 0)) {
      setPendingClose(true)
      return
    }
    overlay.onClose()
  }, [overlay, red, blue])

  const handleSave = useCallback(async () => {
    if (!overlay) return
    setIsSaving(true)
    setSaveError(null)
    try {
      await overlay.onSave(red, blue)
      overlay.onClose()
    } catch (err) {
      console.error('Save failed', err)
      setSaveError(`Save failed: ${err instanceof Error ? err.message : String(err)}`)
    } finally {
      setIsSaving(false)
    }
  }, [overlay, red, blue])

  // Overlay mode: name shown as read-only pill
  const nameA = overlay ? redName : (redName || 'RED')
  const nameB = overlay ? blueName : (blueName || 'BLUE')

  const redSide = (
    <div
      className="flex-1 flex flex-col items-center justify-center relative cursor-pointer active:brightness-150 duration-75"
      style={{ background: '#b91c1c', transitionProperty: 'filter' }}
      onClick={addRed}
    >
      {/* Player name */}
      <div className="absolute top-0 left-0 right-0 flex justify-center pt-5" onClick={e => e.stopPropagation()}>
        {overlay ? (
          <span
            className="uppercase font-bold text-white truncate px-4 py-1 rounded-full pointer-events-none"
            style={{ background: 'rgba(0,0,0,0.25)', fontSize: 'clamp(0.75rem,2.2vmax,1rem)', letterSpacing: '0.12em' }}
          >
            {nameA}
          </span>
        ) : editingRed ? (
          <input
            autoFocus
            placeholder="RED"
            value={redName}
            onChange={e => setRedName(e.target.value)}
            onBlur={() => setEditingRed(false)}
            onKeyDown={e => { if (e.key === 'Enter') setEditingRed(false) }}
            className="bg-transparent text-center text-white/70 font-bold uppercase outline-none border-b border-white/30 w-36"
            style={{ fontSize: 'clamp(0.7rem,2vmax,1rem)', letterSpacing: '0.18em' }}
          />
        ) : (
          <span
            className={`uppercase font-bold cursor-text border-b border-transparent hover:border-white/20 transition-colors ${redName ? 'text-white/50' : 'text-white/30'}`}
            style={{ fontSize: 'clamp(0.7rem,2vmax,1rem)', letterSpacing: '0.18em' }}
            onClick={() => setEditingRed(true)}
          >
            {nameA}
          </span>
        )}
      </div>

      {/* Score */}
      <span
        className="text-white font-black leading-none pointer-events-none"
        style={{
          fontSize: 'clamp(6rem, 22vmax, 13rem)',
          transform: popRed ? 'scale(1.1)' : 'scale(1)',
          transition: 'transform 0.08s ease-out',
        }}
      >
        {red}
      </span>
      <span
        className="text-white/20 tracking-widest mt-3 pointer-events-none"
        style={{ fontSize: 'clamp(0.55rem,1.2vmax,0.75rem)' }}
      >
        tap to score
      </span>

      <button
        onClick={minusRed}
        className="absolute right-4 top-1/2 -translate-y-1/2 w-11 h-11 rounded-full flex items-center justify-center text-xl font-bold text-white/60 cursor-pointer active:bg-black/40 transition-colors"
        style={{ background: 'rgba(0,0,0,0.22)', border: '1px solid rgba(255,255,255,0.15)' }}
      >
        −
      </button>
    </div>
  )

  const blueSide = (
    <div
      className="flex-1 flex flex-col items-center justify-center relative cursor-pointer active:brightness-150 duration-75"
      style={{ background: '#1d4ed8', transitionProperty: 'filter' }}
      onClick={addBlue}
    >
      {/* Player name */}
      <div className="absolute top-0 left-0 right-0 flex justify-center pt-5" onClick={e => e.stopPropagation()}>
        {overlay ? (
          <span
            className="uppercase font-bold text-white truncate px-4 py-1 rounded-full pointer-events-none"
            style={{ background: 'rgba(0,0,0,0.25)', fontSize: 'clamp(0.75rem,2.2vmax,1rem)', letterSpacing: '0.12em' }}
          >
            {nameB}
          </span>
        ) : editingBlue ? (
          <input
            autoFocus
            placeholder="BLUE"
            value={blueName}
            onChange={e => setBlueName(e.target.value)}
            onBlur={() => setEditingBlue(false)}
            onKeyDown={e => { if (e.key === 'Enter') setEditingBlue(false) }}
            className="bg-transparent text-center text-white/70 font-bold uppercase outline-none border-b border-white/30 w-36"
            style={{ fontSize: 'clamp(0.7rem,2vmax,1rem)', letterSpacing: '0.18em' }}
          />
        ) : (
          <span
            className={`uppercase font-bold cursor-text border-b border-transparent hover:border-white/20 transition-colors ${blueName ? 'text-white/50' : 'text-white/30'}`}
            style={{ fontSize: 'clamp(0.7rem,2vmax,1rem)', letterSpacing: '0.18em' }}
            onClick={() => setEditingBlue(true)}
          >
            {nameB}
          </span>
        )}
      </div>

      {/* Score */}
      <span
        className="text-white font-black leading-none pointer-events-none"
        style={{
          fontSize: 'clamp(6rem, 22vmax, 13rem)',
          transform: popBlue ? 'scale(1.1)' : 'scale(1)',
          transition: 'transform 0.08s ease-out',
        }}
      >
        {blue}
      </span>
      <span
        className="text-white/20 tracking-widest mt-3 pointer-events-none"
        style={{ fontSize: 'clamp(0.55rem,1.2vmax,0.75rem)' }}
      >
        tap to score
      </span>

      <button
        onClick={minusBlue}
        className="absolute left-4 top-1/2 -translate-y-1/2 w-11 h-11 rounded-full flex items-center justify-center text-xl font-bold text-white/60 cursor-pointer active:bg-black/40 transition-colors"
        style={{ background: 'rgba(0,0,0,0.22)', border: '1px solid rgba(255,255,255,0.15)' }}
      >
        −
      </button>
    </div>
  )

  const divider = (
    <div
      className="absolute left-1/2 w-px bg-white/8 pointer-events-none z-10"
      style={{ top: '10%', height: '80%' }}
    />
  )

  const footer = (
    <div
      className="fixed bottom-0 left-0 right-0 flex items-center justify-center gap-4 z-20 pointer-events-none"
      style={{
        paddingTop: '0.5rem',
        paddingBottom: 'max(0.75rem, env(safe-area-inset-bottom))',
      }}
    >
      {overlay ? (
        pendingClose ? (
          <>
            <span className="text-white/50 text-xs pointer-events-auto">Discard score?</span>
            <button
              onClick={overlay.onClose}
              className="px-4 py-1 rounded-lg text-white/80 text-sm cursor-pointer active:bg-white/10 transition-colors pointer-events-auto"
              style={{ background: 'rgba(255,255,255,0.12)', border: '1px solid rgba(255,255,255,0.2)' }}
            >
              Discard
            </button>
            <button
              onClick={() => setPendingClose(false)}
              className="px-4 py-1 rounded-lg text-slate-900 font-bold text-sm cursor-pointer active:opacity-80 transition-opacity pointer-events-auto"
              style={{ background: '#fbbf24' }}
            >
              Keep scoring
            </button>
          </>
        ) : (
          <>
            <button
              onClick={handleOverlayClose}
              disabled={isSaving}
              className="px-3 h-9 flex items-center rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto disabled:opacity-30 disabled:cursor-not-allowed"
              style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
            >
              ✕
            </button>
            <button
              onClick={reset}
              className="px-3 h-9 flex items-center rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto"
              style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
            >
              ↺
            </button>
            <button
              onClick={doSwap}
              className="px-3 h-9 flex items-center rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto"
              style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
            >
              ⇄
            </button>
            <button
              onClick={toggleFullscreen}
              className="px-3 h-9 flex items-center rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto"
              style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
            >
              {isFullscreen ? '⊠' : '⛶'}
            </button>
            <button
              onClick={handleSave}
              disabled={isSaving}
              className="px-4 h-9 flex items-center rounded-lg text-slate-900 font-bold text-sm cursor-pointer active:opacity-80 transition-opacity pointer-events-auto disabled:opacity-50 disabled:cursor-not-allowed"
              style={{ background: '#fbbf24' }}
            >
              {isSaving ? (
                <>
                  <svg className="animate-spin w-3.5 h-3.5 mr-1.5 shrink-0" viewBox="0 0 24 24" fill="none">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                  </svg>
                  Saving…
                </>
              ) : 'Save Score'}
            </button>
          </>
        )
      ) : (
        <>
          <button
            onClick={async () => { await exitFullscreen(); navigate('/') }}
            className="px-3 py-1 rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto"
            style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
          >
            ←
          </button>
          <button
            onClick={reset}
            className="px-3 py-1 rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto"
            style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
          >
            ↺
          </button>
          <button
            onClick={doSwap}
            className="px-3 py-1 rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto"
            style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
          >
            ⇄
          </button>
          <button
            onClick={toggleFullscreen}
            className="px-3 py-1 rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors pointer-events-auto"
            style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
          >
            {isFullscreen ? '⊠' : '⛶'}
          </button>
        </>
      )}
    </div>
  )

  if (overlay) {
    return (
      <div
        className="flex overflow-hidden select-none"
        style={isPortrait ? {
          position: 'fixed',
          top: 0,
          left: '100vw',
          width: '100dvh',
          height: '100dvw',
          transformOrigin: 'top left',
          transform: 'rotate(90deg)',
          zIndex: 60,
        } : {
          position: 'fixed',
          inset: 0,
          zIndex: 60,
        }}
      >
        {isSwapped ? blueSide : redSide}
        {divider}
        {isSwapped ? redSide : blueSide}
        {fsError && (
          <div
            className="fixed bottom-14 left-1/2 -translate-x-1/2 z-30 px-4 py-2 rounded-lg text-xs text-white/80 text-center"
            style={{ maxWidth: '80vw', background: 'rgba(0,0,0,0.75)', border: '1px solid rgba(255,255,255,0.15)' }}
          >
            {fsError}
          </div>
        )}
        {saveError && (
          <div
            className="fixed bottom-24 left-1/2 -translate-x-1/2 z-30 px-4 py-2 rounded-lg text-xs text-red-200 text-center"
            style={{ maxWidth: '80vw', background: 'rgba(127,29,29,0.9)', border: '1px solid rgba(220,38,38,0.4)' }}
          >
            {saveError}
          </div>
        )}
        {footer}
      </div>
    )
  }

  // Standalone page mode
  return (
    <div
      className="flex overflow-hidden select-none"
      style={isPortrait ? {
        position: 'fixed',
        top: 0,
        left: '100vw',
        width: '100dvh',
        height: '100dvw',
        transformOrigin: 'top left',
        transform: 'rotate(90deg)',
      } : {
        width: '100vw',
        height: '100dvh',
      }}
    >
      {isSwapped ? blueSide : redSide}
      {divider}
      {isSwapped ? redSide : blueSide}
      {fsError && (
        <div
          className="fixed bottom-14 left-1/2 -translate-x-1/2 z-30 px-4 py-2 rounded-lg text-xs text-white/80 text-center"
          style={{ maxWidth: '80vw', background: 'rgba(0,0,0,0.75)', border: '1px solid rgba(255,255,255,0.15)' }}
        >
          {fsError}
        </div>
      )}
      {footer}
    </div>
  )
}
