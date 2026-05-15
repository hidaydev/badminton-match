import { useState, useCallback, useEffect, useRef } from 'react'

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
  } catch {}
  return null
}

async function exitFullscreen() {
  try {
    if (document.fullscreenElement) await document.exitFullscreen()
  } catch {}
}

export default function ScoreboardPage() {
  const [red, setRed] = useState(() => readLS(LS_RED))
  const [blue, setBlue] = useState(() => readLS(LS_BLUE))
  const [redName, setRedName] = useState(() => { const v = localStorage.getItem('name-red'); return (v === 'Red' || v === null) ? '' : v })
  const [blueName, setBlueName] = useState(() => { const v = localStorage.getItem('name-blue'); return (v === 'Blue' || v === null) ? '' : v })
  const [editingRed, setEditingRed] = useState(false)
  const [editingBlue, setEditingBlue] = useState(false)
  const [popRed, setPopRed] = useState(false)
  const [popBlue, setPopBlue] = useState(false)
  const [isFullscreen, setIsFullscreen] = useState(() => !!document.fullscreenElement)
  const [fsError, setFsError] = useState<string | null>(null)

  const redTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const blueTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const fsErrorTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => { localStorage.setItem(LS_RED, String(red)) }, [red])
  useEffect(() => { localStorage.setItem(LS_BLUE, String(blue)) }, [blue])
  useEffect(() => { localStorage.setItem('name-red', redName) }, [redName])
  useEffect(() => { localStorage.setItem('name-blue', blueName) }, [blueName])

  useEffect(() => {
    const onChange = () => setIsFullscreen(!!document.fullscreenElement)
    document.addEventListener('fullscreenchange', onChange)
    return () => {
      document.removeEventListener('fullscreenchange', onChange)
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

  const addRed = useCallback(() => { setRed(r => r + 1); triggerPop('red') }, [])
  const addBlue = useCallback(() => { setBlue(b => b + 1); triggerPop('blue') }, [])

  const minusRed = useCallback((e: React.MouseEvent) => {
    e.stopPropagation()
    setRed(r => Math.max(0, r - 1))
    triggerPop('red')
  }, [])

  const minusBlue = useCallback((e: React.MouseEvent) => {
    e.stopPropagation()
    setBlue(b => Math.max(0, b - 1))
    triggerPop('blue')
  }, [])

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
    setRed(blue)
    setBlue(red)
    setRedName(blueName)
    setBlueName(redName)
  }, [red, blue, redName, blueName])

  return (
    <div className="flex w-screen h-screen overflow-hidden select-none">

      {/* Red side */}
      <div
        className="flex-1 flex flex-col items-center justify-center relative cursor-pointer active:brightness-150 transition-[filter] duration-75"
        style={{ background: '#b91c1c' }}
        onClick={addRed}
      >
        {editingRed ? (
          <input
            autoFocus
            placeholder="Player name"
            value={redName}
            onChange={e => setRedName(e.target.value)}
            onBlur={() => setEditingRed(false)}
            onKeyDown={e => { if (e.key === 'Enter') setEditingRed(false) }}
            onClick={e => e.stopPropagation()}
            className="bg-transparent text-center text-white/70 font-bold uppercase tracking-[0.18em] outline-none border-b border-white/30 w-48"
            style={{ fontSize: 'clamp(1rem,3vw,1.5rem)' }}
          />
        ) : (
          <span
            className={`text-[clamp(1rem,3vw,1.5rem)] tracking-[0.18em] uppercase font-bold cursor-text border-b border-transparent hover:border-white/20 transition-colors ${redName ? 'text-white/50' : 'text-white/25 italic'}`}
            onClick={e => { e.stopPropagation(); setEditingRed(true) }}
          >
            {redName || 'Player name'}
          </span>
        )}
        <span
          className="text-white font-black leading-none pointer-events-none"
          style={{
            fontSize: 'clamp(6rem, 22vw, 13rem)',
            transform: popRed ? 'scale(1.1)' : 'scale(1)',
            transition: 'transform 0.08s ease-out',
          }}
        >
          {red}
        </span>
        <span className="text-white/20 text-[clamp(0.5rem,1vw,0.7rem)] tracking-widest mt-3 pointer-events-none">
          tap to score
        </span>
        <button
          onClick={minusRed}
          className="absolute bottom-14 w-11 h-11 rounded-full flex items-center justify-center text-xl font-bold text-white/60 cursor-pointer active:bg-black/40 transition-colors"
          style={{ background: 'rgba(0,0,0,0.22)', border: '1px solid rgba(255,255,255,0.15)' }}
        >
          −
        </button>
      </div>

      {/* Divider */}
      <div className="absolute left-1/2 top-[10%] h-[80%] w-px bg-white/8 pointer-events-none z-10" />

      {/* Blue side */}
      <div
        className="flex-1 flex flex-col items-center justify-center relative cursor-pointer active:brightness-150 transition-[filter] duration-75"
        style={{ background: '#1d4ed8' }}
        onClick={addBlue}
      >
        {editingBlue ? (
          <input
            autoFocus
            placeholder="Player name"
            value={blueName}
            onChange={e => setBlueName(e.target.value)}
            onBlur={() => setEditingBlue(false)}
            onKeyDown={e => { if (e.key === 'Enter') setEditingBlue(false) }}
            onClick={e => e.stopPropagation()}
            className="bg-transparent text-center text-white/70 font-bold uppercase tracking-[0.18em] outline-none border-b border-white/30 w-48"
            style={{ fontSize: 'clamp(1rem,3vw,1.5rem)' }}
          />
        ) : (
          <span
            className={`text-[clamp(1rem,3vw,1.5rem)] tracking-[0.18em] uppercase font-bold cursor-text border-b border-transparent hover:border-white/20 transition-colors ${blueName ? 'text-white/50' : 'text-white/25 italic'}`}
            onClick={e => { e.stopPropagation(); setEditingBlue(true) }}
          >
            {blueName || 'Player name'}
          </span>
        )}
        <span
          className="text-white font-black leading-none pointer-events-none"
          style={{
            fontSize: 'clamp(6rem, 22vw, 13rem)',
            transform: popBlue ? 'scale(1.1)' : 'scale(1)',
            transition: 'transform 0.08s ease-out',
          }}
        >
          {blue}
        </span>
        <span className="text-white/20 text-[clamp(0.5rem,1vw,0.7rem)] tracking-widest mt-3 pointer-events-none">
          tap to score
        </span>
        <button
          onClick={minusBlue}
          className="absolute bottom-14 w-11 h-11 rounded-full flex items-center justify-center text-xl font-bold text-white/60 cursor-pointer active:bg-black/40 transition-colors"
          style={{ background: 'rgba(0,0,0,0.22)', border: '1px solid rgba(255,255,255,0.15)' }}
        >
          −
        </button>
      </div>

      {/* Fullscreen error toast */}
      {fsError && (
        <div className="absolute bottom-14 left-1/2 -translate-x-1/2 z-30 px-4 py-2 rounded-lg text-xs text-white/80 max-w-[80vw] text-center"
          style={{ background: 'rgba(0,0,0,0.75)', border: '1px solid rgba(255,255,255,0.15)' }}>
          {fsError}
        </div>
      )}

      {/* Bottom action bar */}
      <div
        className="absolute bottom-0 left-0 right-0 h-12 flex items-center justify-center gap-4 z-20"
        style={{ background: 'rgba(0,0,0,0.35)', borderTop: '1px solid rgba(255,255,255,0.06)' }}
      >
        <button
          onClick={reset}
          className="px-5 py-1.5 rounded-lg text-white/55 text-[0.72rem] tracking-wide cursor-pointer active:bg-white/10 transition-colors"
          style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
        >
          ↺ Reset
        </button>
        <button
          onClick={doSwap}
          className="px-5 py-1.5 rounded-lg text-white/55 text-[0.72rem] tracking-wide cursor-pointer active:bg-white/10 transition-colors"
          style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
        >
          ⇄ Swap
        </button>
        <button
          onClick={toggleFullscreen}
          className="px-5 py-1.5 rounded-lg text-white/55 text-[0.72rem] tracking-wide cursor-pointer active:bg-white/10 transition-colors"
          style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
        >
          {isFullscreen ? '⊠ Exit' : '⛶ Fullscreen'}
        </button>
      </div>

    </div>
  )
}
