import { useState, useEffect, useCallback } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { getSession, publishSession, type CloudSnapshot } from '../utils/cloudSync'
import type { GeneratorResult } from '../generator'
import type { GameScore } from '../store'
import SummaryModal from '../components/SummaryModal'

export default function SharedSessionPage() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const navigate = useNavigate()

  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [snapshot, setSnapshot] = useState<CloudSnapshot | null>(null)
  const [playedGames, setPlayedGames] = useState<string[]>([])
  const [gameScores, setGameScores] = useState<Record<string, GameScore>>({})

  const fetchSession = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const data = await getSession(sessionId!)
      if (!data) { setError('Session not found.'); return }
      setSnapshot(data)
      setPlayedGames(data.playedGames)
      setGameScores(data.gameScores)
    } catch {
      setError('Failed to load session. Check your connection.')
    } finally {
      setLoading(false)
    }
  }, [sessionId])

  useEffect(() => { fetchSession() }, [fetchSession])

  async function handleTogglePlayed(key: string) {
    if (!snapshot) return
    const next = playedGames.includes(key)
      ? playedGames.filter((k) => k !== key)
      : [...playedGames, key]
    setPlayedGames(next)
    const updated: CloudSnapshot = { ...snapshot, playedGames: next, gameScores }
    setSnapshot(updated)
    try { await publishSession(sessionId!, updated) } catch { /* silent — local state updated */ }
  }

  async function handleSetScore(key: string, a: number, b: number) {
    if (!snapshot) return
    const nextScores = { ...gameScores, [key]: { a, b } }
    setGameScores(nextScores)
    const updated: CloudSnapshot = { ...snapshot, playedGames, gameScores: nextScores }
    setSnapshot(updated)
    try { await publishSession(sessionId!, updated) } catch { /* silent */ }
  }

  if (loading) {
    return (
      <div className="fixed inset-0 bg-slate-950 flex items-center justify-center">
        <span className="text-slate-400 text-sm">Loading session…</span>
      </div>
    )
  }

  if (error || !snapshot) {
    return (
      <div className="fixed inset-0 bg-slate-950 flex flex-col items-center justify-center gap-4">
        <span className="text-slate-300 text-sm">{error ?? 'Session not found.'}</span>
        <button
          onClick={() => navigate('/')}
          className="text-xs text-indigo-400 hover:text-white underline underline-offset-2"
        >
          Go to home
        </button>
      </div>
    )
  }

  const playerMap = new Map(snapshot.players.map((p) => [p.id, p]))

  const result: GeneratorResult = {
    schedule: snapshot.schedule,
    playCount: {},
    sitCount: {},
    partnerWith: {},
    facedBy: {},
    unplacedFixMatches: [],
  }

  return (
    <SummaryModal
      result={result}
      playerMap={playerMap}
      slotsPerCourt={snapshot.session.slotsPerCourt}
      courtNames={snapshot.session.courtNames ?? []}
      playedGames={playedGames}
      gameScores={gameScores}
      onTogglePlayedGame={handleTogglePlayed}
      onSetGameScore={handleSetScore}
      title={snapshot.session.title ?? ''}
      date={snapshot.session.date ?? ''}
      sessionStart={snapshot.session.sessionStart}
      slotMinutes={snapshot.session.slotMinutes}
      courtTimes={snapshot.session.courtTimes}
    />
  )
}
