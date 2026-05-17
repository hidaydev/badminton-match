import { useState, useCallback, useRef, useEffect } from 'react'

interface Props {
  matchId: string
  pairAName: string
  pairBName: string
  onSave: (scoreA: number, scoreB: number) => void
  onClose: () => void
}

function readLS(key: string): number {
  const v = localStorage.getItem(key)
  if (v === null) return 0
  const parsed = parseInt(v, 10)
  return Number.isFinite(parsed) ? parsed : 0
}

export default function ScoreboardOverlay({ matchId, pairAName, pairBName, onSave, onClose }: Props) {
  const keyA = `score-match-${matchId}-a`
  const keyB = `score-match-${matchId}-b`

  const [scoreA, setScoreA] = useState(() => readLS(keyA))
  const [scoreB, setScoreB] = useState(() => readLS(keyB))
  const [popA, setPopA] = useState(false)
  const [popB, setPopB] = useState(false)

  const initialA = useRef(readLS(keyA))
  const initialB = useRef(readLS(keyB))
  const timerA = useRef<ReturnType<typeof setTimeout> | null>(null)
  const timerB = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => { localStorage.setItem(keyA, String(scoreA)) }, [scoreA, keyA])
  useEffect(() => { localStorage.setItem(keyB, String(scoreB)) }, [scoreB, keyB])

  useEffect(() => {
    return () => {
      if (timerA.current) clearTimeout(timerA.current)
      if (timerB.current) clearTimeout(timerB.current)
    }
  }, [])

  function triggerPop(side: 'a' | 'b') {
    if (side === 'a') {
      setPopA(true)
      if (timerA.current) clearTimeout(timerA.current)
      timerA.current = setTimeout(() => setPopA(false), 180)
    } else {
      setPopB(true)
      if (timerB.current) clearTimeout(timerB.current)
      timerB.current = setTimeout(() => setPopB(false), 180)
    }
  }

  const addA = useCallback(() => { setScoreA(s => s + 1); triggerPop('a') }, [])
  const addB = useCallback(() => { setScoreB(s => s + 1); triggerPop('b') }, [])

  const minusA = useCallback((e: React.MouseEvent) => {
    e.stopPropagation()
    setScoreA(s => Math.max(0, s - 1))
    triggerPop('a')
  }, [])

  const minusB = useCallback((e: React.MouseEvent) => {
    e.stopPropagation()
    setScoreB(s => Math.max(0, s - 1))
    triggerPop('b')
  }, [])

  const reset = useCallback(() => { setScoreA(0); setScoreB(0) }, [])

  const swap = useCallback(() => {
    setScoreA(scoreB)
    setScoreB(scoreA)
  }, [scoreA, scoreB])

  const handleClose = useCallback(() => {
    if (scoreA !== initialA.current || scoreB !== initialB.current) {
      if (!window.confirm('Discard unsaved score?')) return
    }
    onClose()
  }, [scoreA, scoreB, onClose])

  const handleSave = useCallback(() => {
    onSave(scoreA, scoreB)
    onClose()
  }, [scoreA, scoreB, onSave, onClose])

  return (
    <div className="fixed inset-0 z-[60] flex flex-col select-none">
      {/* Score area */}
      <div className="flex flex-1 overflow-hidden">
        {/* Side A — red */}
        <div
          className="flex-1 flex flex-col items-center justify-center relative cursor-pointer active:brightness-150 transition-[filter] duration-75"
          style={{ background: '#b91c1c' }}
          onClick={addA}
        >
          <div className="absolute top-0 left-0 right-0 flex justify-center pt-4 pointer-events-none">
            <span className="text-[clamp(0.65rem,2vmax,0.9rem)] tracking-[0.18em] uppercase font-bold text-white/40 truncate px-4 text-center">
              {pairAName}
            </span>
          </div>
          <span
            className="text-white font-black leading-none pointer-events-none"
            style={{
              fontSize: 'clamp(6rem, 22vmax, 13rem)',
              transform: popA ? 'scale(1.1)' : 'scale(1)',
              transition: 'transform 0.08s ease-out',
            }}
          >
            {scoreA}
          </span>
          <span className="text-white/20 text-[clamp(0.55rem,1.2vmax,0.75rem)] tracking-widest mt-3 pointer-events-none">
            tap to score
          </span>
          <button
            onClick={minusA}
            className="absolute right-4 top-1/2 -translate-y-1/2 w-11 h-11 rounded-full flex items-center justify-center text-xl font-bold text-white/60 cursor-pointer active:bg-black/40 transition-colors"
            style={{ background: 'rgba(0,0,0,0.22)', border: '1px solid rgba(255,255,255,0.15)' }}
          >
            −
          </button>
        </div>

        {/* Divider */}
        <div className="absolute left-1/2 top-[10%] h-[80%] w-px bg-white/8 pointer-events-none z-10" />

        {/* Side B — blue */}
        <div
          className="flex-1 flex flex-col items-center justify-center relative cursor-pointer active:brightness-150 transition-[filter] duration-75"
          style={{ background: '#1d4ed8' }}
          onClick={addB}
        >
          <div className="absolute top-0 left-0 right-0 flex justify-center pt-4 pointer-events-none">
            <span className="text-[clamp(0.65rem,2vmax,0.9rem)] tracking-[0.18em] uppercase font-bold text-white/40 truncate px-4 text-center">
              {pairBName}
            </span>
          </div>
          <span
            className="text-white font-black leading-none pointer-events-none"
            style={{
              fontSize: 'clamp(6rem, 22vmax, 13rem)',
              transform: popB ? 'scale(1.1)' : 'scale(1)',
              transition: 'transform 0.08s ease-out',
            }}
          >
            {scoreB}
          </span>
          <span className="text-white/20 text-[clamp(0.55rem,1.2vmax,0.75rem)] tracking-widest mt-3 pointer-events-none">
            tap to score
          </span>
          <button
            onClick={minusB}
            className="absolute left-4 top-1/2 -translate-y-1/2 w-11 h-11 rounded-full flex items-center justify-center text-xl font-bold text-white/60 cursor-pointer active:bg-black/40 transition-colors"
            style={{ background: 'rgba(0,0,0,0.22)', border: '1px solid rgba(255,255,255,0.15)' }}
          >
            −
          </button>
        </div>
      </div>

      {/* Footer action bar */}
      <div
        className="flex items-center justify-center gap-3 z-20"
        style={{
          paddingTop: '0.5rem',
          paddingBottom: 'max(0.75rem, env(safe-area-inset-bottom))',
          background: 'rgba(0,0,0,0.35)',
          borderTop: '1px solid rgba(255,255,255,0.08)',
        }}
      >
        <button
          onClick={handleClose}
          className="px-3 py-1 rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors"
          style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
        >
          ←
        </button>
        <button
          onClick={reset}
          className="px-3 py-1 rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors"
          style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
        >
          ↺
        </button>
        <button
          onClick={swap}
          className="px-3 py-1 rounded-lg text-white/55 text-lg cursor-pointer active:bg-white/10 transition-colors"
          style={{ background: 'rgba(255,255,255,0.06)', border: '1px solid rgba(255,255,255,0.1)' }}
        >
          ⇄
        </button>
        <button
          onClick={handleSave}
          className="px-4 py-1 rounded-lg text-slate-900 font-bold text-sm cursor-pointer active:opacity-80 transition-opacity"
          style={{ background: '#fbbf24' }}
        >
          Save Score
        </button>
      </div>
    </div>
  )
}
