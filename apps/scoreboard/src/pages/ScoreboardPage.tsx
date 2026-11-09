import { useState, useCallback, useEffect, useRef, Fragment } from 'react'
import { ScoreboardSide, ScoreboardDivider, ScoreboardFooter } from '../components/scoreboard'
import type { ScoreboardSideProps } from '../components/scoreboard'
import { useStorageUnavailable } from '../hooks/useStorageUnavailable'
import { usePersistentStorage } from '../hooks/usePersistentStorage'
import { readStoredValue, writeStoredValue } from '../utils/storage'
import { SCOREBOARD_LABELS } from '../scoreboardLabels'
import {
  readMatchSnapshot,
  serializeMatchSnapshot,
  shareMatchExport,
} from '../utils/matchExport'

const LS_RED = 'score-red'
const LS_BLUE = 'score-blue'

function readScore(key: string) {
  const v = readStoredValue(key)
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
  const storageUnavailable = useStorageUnavailable()
  const { status: persistenceStatus, requestPersistence } = usePersistentStorage()
  const [red, setRed] = useState(() => readScore(LS_RED))
  const [blue, setBlue] = useState(() => readScore(LS_BLUE))
  const [redName, setRedName] = useState(() => {
    const v = readStoredValue('name-red')
    return (v === 'Red' || v === null) ? '' : v
  })
  const [blueName, setBlueName] = useState(() => {
    const v = readStoredValue('name-blue')
    return (v === 'Blue' || v === null) ? '' : v
  })
  const [editingRed, setEditingRed] = useState(false)
  const [editingBlue, setEditingBlue] = useState(false)
  const [popRed, setPopRed] = useState(false)
  const [popBlue, setPopBlue] = useState(false)
  const [isSwapped, setIsSwapped] = useState(false)
  const [isFullscreen, setIsFullscreen] = useState(() => !!document.fullscreenElement)
  const [fsError, setFsError] = useState<string | null>(null)
  const [exportNotice, setExportNotice] = useState<string | null>(null)
  const [isPortrait, setIsPortrait] = useState(() => window.innerWidth < window.innerHeight)

  const redTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const blueTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const fsErrorTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const exportNoticeTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => { writeStoredValue(LS_RED, String(red)) }, [red])
  useEffect(() => { writeStoredValue(LS_BLUE, String(blue)) }, [blue])
  useEffect(() => { writeStoredValue('name-red', redName) }, [redName])
  useEffect(() => { writeStoredValue('name-blue', blueName) }, [blueName])

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
      if (exportNoticeTimer.current) clearTimeout(exportNoticeTimer.current)
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
  const addRed = useCallback(() => { setRed(r => Math.min(99, r + 1)); triggerPop('red'); requestPersistence() }, [requestPersistence]) // eslint-disable-line react-hooks/exhaustive-deps
  const addBlue = useCallback(() => { setBlue(b => Math.min(99, b + 1)); triggerPop('blue'); requestPersistence() }, [requestPersistence]) // eslint-disable-line react-hooks/exhaustive-deps

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

  const exportMatch = useCallback(async () => {
    const text = serializeMatchSnapshot(readMatchSnapshot())
    const result = await shareMatchExport(text)
    if (result === 'cancelled') return

    if (result === 'failed') setExportNotice('Could not export the match')
    else if (result === 'shared') setExportNotice('Match shared')
    else setExportNotice('Match copied to clipboard')

    if (exportNoticeTimer.current) clearTimeout(exportNoticeTimer.current)
    exportNoticeTimer.current = setTimeout(() => setExportNotice(null), 3000)
  }, [])

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

  const nameA = redName || SCOREBOARD_LABELS.red.displayName
  const nameB = blueName || SCOREBOARD_LABELS.blue.displayName

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
    labels: SCOREBOARD_LABELS.red,
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
    labels: SCOREBOARD_LABELS.blue,
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

  const statusNote = storageUnavailable
    ? 'Scores are not being saved on this device'
    : persistenceStatus === 'persisted'
      ? 'Scores are saved on this device'
      : persistenceStatus === 'not-persisted' || persistenceStatus === 'error'
        ? 'Scores may be cleared by the browser'
        : null

  const redEl = <ScoreboardSide {...redSide} />
  const blueEl = <ScoreboardSide {...blueSide} />
  const sides = isSwapped ? [blueEl, redEl] : [redEl, blueEl]

  return (
    <main className="flex overflow-hidden select-none" style={portraitStyle}>
      <h1 className="sr-only">Scoreboard</h1>
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
      {exportNotice && (
        <div
          role="status"
          className="fixed bottom-24 left-1/2 -translate-x-1/2 z-30 px-4 py-2 rounded-lg text-xs text-white/80 text-center"
          style={{ maxWidth: '80vw', background: 'rgba(0,0,0,0.75)', border: '1px solid rgba(255,255,255,0.15)' }}
        >
          {exportNotice}
        </div>
      )}
      {statusNote && (
        <div
          role="status"
          className="fixed top-0 left-1/2 -translate-x-1/2 z-30 px-3 py-1 rounded-b-lg text-[0.6rem] text-white/80 text-center pointer-events-none"
          style={{ background: 'rgba(0,0,0,0.5)', letterSpacing: '0.08em' }}
        >
          {statusNote}
        </div>
      )}
      <ScoreboardFooter
        labels={SCOREBOARD_LABELS}
        isFullscreen={isFullscreen}
        onReset={reset}
        onSwap={doSwap}
        onExport={exportMatch}
        onToggleFullscreen={toggleFullscreen}
      />
    </main>
  )
}
