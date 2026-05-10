import { useState } from 'react'
import { Link, useParams, useNavigate } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import {
  useGetSession,
  useTogglePlayed,
  useSetScore,
  useSwapPlayers,
  useSetAbsent,
  type CloudSnapshot,
} from '../queries'
import type { GeneratorResult } from '../generator'
import SummaryModal from '../components/SummaryModal'

export default function SharedSessionPage() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [saveError, setSaveError] = useState<string | null>(null)

  const { data: snapshot, isLoading, isError } = useGetSession(sessionId)
  const { mutate: togglePlayed, isPending: togglePlayedPending } = useTogglePlayed(sessionId!)
  const { mutate: setScore, isPending: setScorePending } = useSetScore(sessionId!)
  const { mutate: swapPlayers, isPending: swapPlayersPending } = useSwapPlayers(sessionId!)
  const { mutate: setAbsent, isPending: setAbsentPending } = useSetAbsent(sessionId!)

  const header = (
    <header className="border-b border-slate-800 bg-slate-900/80 backdrop-blur sticky top-0 z-10">
      <div className="max-w-3xl mx-auto px-3 py-3 flex items-center gap-2">
        <Link to="/" className="flex items-center gap-2">
          <img src="/logo.png" alt="logo" className="w-6 h-6 shrink-0 object-contain" />
          <h1 className="text-sm font-bold text-white tracking-tight">MAJADU APP</h1>
        </Link>
      </div>
    </header>
  )

  if (isLoading) {
    return (
      <div className="min-h-screen bg-slate-950 text-slate-100 flex flex-col">
        {header}
        <div className="flex-1 flex items-center justify-center">
          <span className="text-slate-400 text-sm">Loading session…</span>
        </div>
      </div>
    )
  }

  if (isError || !snapshot) {
    return (
      <div className="min-h-screen bg-slate-950 text-slate-100 flex flex-col">
        {header}
        <div className="flex-1 flex flex-col items-center justify-center gap-4">
          <span className="text-slate-300 text-sm">Session not found.</span>
          <button
            onClick={() => navigate('/')}
            className="text-xs text-indigo-400 hover:text-white underline underline-offset-2"
          >
            Go to home
          </button>
        </div>
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

  const isSaving = togglePlayedPending || setScorePending || swapPlayersPending || setAbsentPending

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 flex flex-col">
      {header}
      {saveError && (
        <div className="fixed top-4 left-1/2 -translate-x-1/2 z-[60] bg-red-900/90 border border-red-700 text-red-200 text-xs px-4 py-2 rounded-lg">
          {saveError}
        </div>
      )}
      <SummaryModal
        result={result}
        playerMap={playerMap}
        slotsPerCourt={snapshot.session.slotsPerCourt}
        courtNames={snapshot.session.courtNames ?? []}
        playedGames={snapshot.playedGames}
        gameScores={snapshot.gameScores}
        onTogglePlayedGame={(key) => {
          const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
          const nextPlayed = current?.playedGames.includes(key)
            ? current.playedGames.filter((k) => k !== key)
            : [...(current?.playedGames ?? []), key]
          togglePlayed({ key, nextPlayed }, {
            onSuccess: () => setSaveError(null),
            onError: () => setSaveError('Failed to save, please try again'),
          })
        }}
        onSetGameScore={(key, a, b) => setScore({ key, a, b }, {
          onSuccess: () => setSaveError(null),
          onError: () => setSaveError('Failed to save, please try again'),
        })}
        title={snapshot.session.title ?? ''}
        date={snapshot.session.date ?? ''}
        sessionStart={snapshot.session.sessionStart}
        slotMinutes={snapshot.session.slotMinutes}
        courtTimes={snapshot.session.courtTimes}
        saving={isSaving}
        onSwapPlayers={(t1, t2) => swapPlayers({ t1, t2 }, {
          onSuccess: () => setSaveError(null),
          onError: () => setSaveError('Failed to save, please try again'),
        })}
        absentPlayers={snapshot.absentPlayers ?? []}
        onSetAbsent={(nextAbsent) => setAbsent({ nextAbsent }, {
          onSuccess: () => setSaveError(null),
          onError: () => setSaveError('Failed to save, please try again'),
        })}
        standalone
      />
    </div>
  )
}
