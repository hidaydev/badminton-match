import { useState, useCallback, useEffect, useRef, Fragment } from 'react'
import { ScoreboardSide, ScoreboardDivider, ScoreboardFooter } from '../components/scoreboard'
import type { ScoreboardSideProps } from '../components/scoreboard'

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

export default function ScoreboardPage() {
  const [red, setRed] = useState(() => readLS(LS_RED))
  const [blue, setBlue] = useState(() => readLS(LS_BLUE))
  const [redName, setRedName] = useState(() => {
    const v = localStorage.getItem('name-red')
    return (v === 'Red' || v === null) ? '' : v
  })
  const [blueName, setBlueName] = useState(() => {
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
    const onResize = () => setIsPortrait(window.innerWidth < window.innerHeight)
    window.addEventListener('resize', onResize)
    return () => {
      document.removeEventListener('fullscreenchange', onChange)
      window.removeEventListener('resize', onResize)
      if (redTimer.current) clearTimeout(redTimer.current)
      if (blueTimer.current) clearTimeout(blueTimer.current)
      if (fsErrorTimer.current) clearTimeout(fsErrorTimer.current)
    }
  }, [])

  const triggerPop = useCallback((side: 'red' | 'blue') => {
    if (side === 'red') {
      setPopRed(true)
      if (redTimer.current) clearTimeout(redTimer.current)
      redTimer.current = setTimeout(() => setPopRed(false), 180)
    } else {
      setPopBlue(true)
      if (blueTimer.current) clearTimeout(blueTimer.current)
      blueTimer.current = setTimeout(() => setPopBlue(false), 180)
    }
  }, [])

  // triggerPop is stable (useCallback with [] deps), safe to use without dep
  const addRed = useCallback(() => { setRed(r => Math.min(99, r + 1)); triggerPop('red') }, []) // eslint-disable-line react-hooks/exhaustive-deps
  const addBlue = useCallback(() => { setBlue(b => Math.min(99, b + 1)); triggerPop('blue') }, []) // eslint-disable-line react-hooks/exhaustive-deps

  const minusRed = useCallback((e: React.MouseEvent) => {
    e.stopPropagation()
    setRed(r => Math.max(0, r - 1))
    triggerPop('red')
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

  const minusBlue = useCallback((e: React.MouseEvent) => {
    e.stopPropagation()
    setBlue(b => Math.max(0, b - 1))
    triggerPop('blue')
  }, []) // eslint-disable-line react-hooks/exhaustive-deps

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

  const doSwap = useCallback(() => setIsSwapped(s => !s), [])

  const nameA = redName || 'RED'
  const nameB = blueName || 'BLUE'

  const portraitStyle: React.CSSProperties = isPortrait ? {
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
  }

  const redSide: ScoreboardSideProps = {
    side: 'red',
    score: red,
    displayName: nameA,
    editValue: redName,
    isEditing: editingRed,
    isPop: popRed,
    isOverlay: false,
    onScore: addRed,
    onMinus: minusRed,
    onNameChange: setRedName,
    onStartEditing: () => setEditingRed(true),
    onStopEditing: () => setEditingRed(false),
  }

  const blueSide: ScoreboardSideProps = {
    side: 'blue',
    score: blue,
    displayName: nameB,
    editValue: blueName,
    isEditing: editingBlue,
    isPop: popBlue,
    isOverlay: false,
    onScore: addBlue,
    onMinus: minusBlue,
    onNameChange: setBlueName,
    onStartEditing: () => setEditingBlue(true),
    onStopEditing: () => setEditingBlue(false),
  }

  const redEl = <ScoreboardSide {...redSide} />
  const blueEl = <ScoreboardSide {...blueSide} />
  const sides = isSwapped ? [blueEl, redEl] : [redEl, blueEl]

  return (
    <main className="flex overflow-hidden select-none" style={portraitStyle}>
      {sides.map((el, i) => (
        <Fragment key={i}>
          {i > 0 && <ScoreboardDivider />}
          {el}
        </Fragment>
      ))}
      {fsError && (
        <div
          className="fixed bottom-14 left-1/2 -translate-x-1/2 z-30 px-4 py-2 rounded-lg text-xs text-white/80 text-center"
          style={{ maxWidth: '80vw', background: 'rgba(0,0,0,0.75)', border: '1px solid rgba(255,255,255,0.15)' }}
        >
          {fsError}
        </div>
      )}
      <ScoreboardFooter
        isFullscreen={isFullscreen}
        onReset={reset}
        onSwap={doSwap}
        onToggleFullscreen={toggleFullscreen}
      />
    </main>
  )
}
