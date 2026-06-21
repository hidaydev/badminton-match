import { useState, useEffect } from 'react'
import { Link, useParams, useNavigate } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import {
  useGetSession,
  useTogglePlayed,
  useSetScore,
  useSwapPlayers,
  useSetAbsent,
  useReplacePlayer,
  useSwapSlots,
  useSwapTeams,
  type CloudSnapshot,
} from '../queries'
import { registerPlayer } from '../queries/endpoints'
import type { GeneratorResult } from '../generator'
import type { SlotSwapTarget } from '../utils/slotSwap'
import type { TeamSwapTarget } from '../utils/swap'
import SummaryModal from '../components/SummaryModal'
import { useLastSession } from '../hooks/useLastSession'
import { getSaveErrorMessage } from '../queries/errors'

export default function SharedSessionPage() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [saveError, setSaveError] = useState<string | null>(null)

  const { data: snapshot, isLoading, isError, refetch, isFetching } = useGetSession(sessionId)
  const { mutate: togglePlayed, isPending: togglePlayedPending } = useTogglePlayed(sessionId!)
  const { mutate: setScore, isPending: setScorePending } = useSetScore(sessionId!)
  const { mutate: swapPlayers, isPending: swapPlayersPending } = useSwapPlayers(sessionId!)
  const { mutate: setAbsent, isPending: setAbsentPending } = useSetAbsent(sessionId!)
  const { mutate: replacePlayer, isPending: replacePlayerPending } = useReplacePlayer(sessionId!)
  const { mutate: swapSlots, isPending: swapSlotsPending } = useSwapSlots(sessionId!)
  const { mutate: swapTeams, isPending: swapTeamsPending } = useSwapTeams(sessionId!)

  const { save } = useLastSession()

  useEffect(() => {
    if (!snapshot || !sessionId) return
    save({
      id: sessionId,
      title: snapshot.session.title,
      date: snapshot.session.date,
      playerCount: snapshot.players.length,
      totalGames: snapshot.schedule.length,
    })
  }, [save, sessionId, snapshot])

  const header = (
    <header className="border-b border-slate-800 bg-slate-900/80 backdrop-blur sticky top-0 z-10">
      <div className="max-w-3xl mx-auto px-3 py-3 flex items-center gap-2">
        <button onClick={() => navigate(-1)} className="p-1.5 rounded-lg text-slate-400 hover:text-white active:scale-90 transition-all shrink-0" aria-label="Back">
          <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
            <path d="M15 18l-6-6 6-6"/>
          </svg>
        </button>
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

  const isSaving = togglePlayedPending || setScorePending || swapPlayersPending || setAbsentPending || replacePlayerPending || swapSlotsPending || swapTeamsPending

  return (
    <div className="min-h-screen bg-slate-950 text-slate-100 flex flex-col">
      {header}
      {saveError && (
        <div className="fixed top-4 left-1/2 -translate-x-1/2 z-60 bg-red-900/90 border border-red-700 text-red-200 text-xs px-4 py-2 rounded-lg">
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
            onError: (err) => setSaveError(getSaveErrorMessage(err)),
          })
        }}
        onSetGameScore={(key, a, b) => setScore({ key, a, b }, {
          onSuccess: () => setSaveError(null),
          onError: (err) => setSaveError(getSaveErrorMessage(err)),
        })}
        title={snapshot.session.title ?? ''}
        date={snapshot.session.date ?? ''}
        sessionStart={snapshot.session.sessionStart}
        slotMinutes={snapshot.session.slotMinutes}
        courtTimes={snapshot.session.courtTimes}
        saving={isSaving}
        onSwapPlayers={(t1, t2) => swapPlayers({ t1, t2 }, {
          onSuccess: () => setSaveError(null),
          onError: (err) => setSaveError(getSaveErrorMessage(err)),
        })}
        absentPlayers={snapshot.absentPlayers ?? []}
        onSetAbsent={(nextAbsent) => setAbsent({ nextAbsent }, {
          onSuccess: () => setSaveError(null),
          onError: (err) => setSaveError(getSaveErrorMessage(err)),
        })}
        onReplacePlayer={async (playerId, newName) => {
          try {
            await registerPlayer(newName)
          } catch (err) {
            setSaveError(getSaveErrorMessage(err))
            return
          }
          replacePlayer({ playerId, newName }, {
            onSuccess: () => setSaveError(null),
            onError: (err) => setSaveError(getSaveErrorMessage(err)),
          })
        }}
        onSwapSlots={(g1: SlotSwapTarget, g2: SlotSwapTarget) => swapSlots({ g1, g2 }, {
          onSuccess: () => setSaveError(null),
          onError: (err) => setSaveError(getSaveErrorMessage(err)),
        })}
        onSwapTeams={(t1: TeamSwapTarget, t2: TeamSwapTarget) => swapTeams({ t1, t2 }, {
          onSuccess: () => setSaveError(null),
          onError: (err) => setSaveError(getSaveErrorMessage(err)),
        })}
        standalone
        onRefetch={() => refetch()}
        isRefetching={isFetching}
      />
    </div>
  )
}
