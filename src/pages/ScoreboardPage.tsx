import { useState, useCallback, useEffect, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { ScoreboardSide, ScoreboardDivider, ScoreboardFooter } from '../components/scoreboard'

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

  const handleBack = useCallback(async () => {
    await exitFullscreen()
    navigate('/')
  }, [navigate])

  // Overlay mode: name shown as read-only pill
  const nameA = overlay ? redName : (redName || 'RED')
  const nameB = overlay ? blueName : (blueName || 'BLUE')

  const portraitStyle: React.CSSProperties = isPortrait ? {
    position: 'fixed',
    top: 0,
    left: '100vw',
    width: '100dvh',
    height: '100dvw',
    transformOrigin: 'top left',
    transform: 'rotate(90deg)',
    ...(overlay ? { zIndex: 60 } : {}),
  } : overlay ? {
    position: 'fixed',
    inset: 0,
    zIndex: 60,
  } : {
    width: '100vw',
    height: '100dvh',
  }

  const content = (
    <>
      {isSwapped ? (
        <ScoreboardSide
          side="blue"
          score={blue}
          displayName={nameB}
          editValue={blueName}
          isEditing={editingBlue}
          isPop={popBlue}
          isOverlay={!!overlay}
          onScore={addBlue}
          onMinus={minusBlue}
          onNameChange={setBlueName}
          onStartEditing={() => setEditingBlue(true)}
          onStopEditing={() => setEditingBlue(false)}
        />
      ) : (
        <ScoreboardSide
          side="red"
          score={red}
          displayName={nameA}
          editValue={redName}
          isEditing={editingRed}
          isPop={popRed}
          isOverlay={!!overlay}
          onScore={addRed}
          onMinus={minusRed}
          onNameChange={setRedName}
          onStartEditing={() => setEditingRed(true)}
          onStopEditing={() => setEditingRed(false)}
        />
      )}
      <ScoreboardDivider />
      {isSwapped ? (
        <ScoreboardSide
          side="red"
          score={red}
          displayName={nameA}
          editValue={redName}
          isEditing={editingRed}
          isPop={popRed}
          isOverlay={!!overlay}
          onScore={addRed}
          onMinus={minusRed}
          onNameChange={setRedName}
          onStartEditing={() => setEditingRed(true)}
          onStopEditing={() => setEditingRed(false)}
        />
      ) : (
        <ScoreboardSide
          side="blue"
          score={blue}
          displayName={nameB}
          editValue={blueName}
          isEditing={editingBlue}
          isPop={popBlue}
          isOverlay={!!overlay}
          onScore={addBlue}
          onMinus={minusBlue}
          onNameChange={setBlueName}
          onStartEditing={() => setEditingBlue(true)}
          onStopEditing={() => setEditingBlue(false)}
        />
      )}
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
      <ScoreboardFooter
        isFullscreen={isFullscreen}
        onReset={reset}
        onSwap={doSwap}
        onToggleFullscreen={toggleFullscreen}
        overlay={overlay ? {
          pendingClose,
          isSaving,
          onClose: handleOverlayClose,
          onSave: handleSave,
          onDiscard: overlay.onClose,
          onKeepScoring: () => setPendingClose(false),
        } : undefined}
        onBack={overlay ? undefined : handleBack}
      />
    </>
  )

  if (overlay) {
    return (
      <div className="flex overflow-hidden select-none" style={portraitStyle}>
        {content}
      </div>
    )
  }

  return (
    <main className="flex overflow-hidden select-none" style={portraitStyle}>
      {content}
    </main>
  )
}
