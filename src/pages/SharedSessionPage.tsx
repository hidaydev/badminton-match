import { useState } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { getSession, publishSession, type CloudSnapshot } from '../utils/cloudSync'
import type { GeneratorResult } from '../generator'
import SummaryModal from '../components/SummaryModal'

export default function SharedSessionPage() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [saveError, setSaveError] = useState<string | null>(null)

  const { data: snapshot, isLoading, isError } = useQuery<CloudSnapshot | null>({
    queryKey: ['session', sessionId],
    queryFn: () => getSession(sessionId!),
    enabled: !!sessionId,
  })

  const togglePlayed = useMutation({
    mutationFn: async (key: string) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const nextPlayed = current.playedGames.includes(key)
        ? current.playedGames.filter((k) => k !== key)
        : [...current.playedGames, key]
      const updated: CloudSnapshot = { ...current, playedGames: nextPlayed }
      await publishSession(sessionId!, updated)
      return updated
    },
    onMutate: async (key) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        const nextPlayed = old.playedGames.includes(key)
          ? old.playedGames.filter((k) => k !== key)
          : [...old.playedGames, key]
        return { ...old, playedGames: nextPlayed }
      })
      return { previous }
    },
    onSuccess: () => setSaveError(null),
    onError: (_err, _key, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
      setSaveError('Failed to save, please try again')
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })

  const setScore = useMutation({
    mutationFn: async ({ key, a, b }: { key: string; a: number; b: number }) => {
      const current = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      if (!current) throw new Error('no data')
      const nextScores = { ...current.gameScores, [key]: { a, b } }
      const nextPlayed = current.playedGames.includes(key)
        ? current.playedGames
        : [...current.playedGames, key]
      const updated: CloudSnapshot = { ...current, gameScores: nextScores, playedGames: nextPlayed }
      await publishSession(sessionId!, updated)
      return updated
    },
    onMutate: async ({ key, a, b }) => {
      await queryClient.cancelQueries({ queryKey: ['session', sessionId] })
      const previous = queryClient.getQueryData<CloudSnapshot>(['session', sessionId])
      queryClient.setQueryData<CloudSnapshot | null>(['session', sessionId], (old) => {
        if (!old) return old
        const nextScores = { ...old.gameScores, [key]: { a, b } }
        const nextPlayed = old.playedGames.includes(key)
          ? old.playedGames
          : [...old.playedGames, key]
        return { ...old, gameScores: nextScores, playedGames: nextPlayed }
      })
      return { previous }
    },
    onSuccess: () => setSaveError(null),
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['session', sessionId], context?.previous)
      setSaveError('Failed to save, please try again')
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ['session', sessionId] })
    },
  })

  if (isLoading) {
    return (
      <div className="fixed inset-0 bg-slate-950 flex items-center justify-center">
        <span className="text-slate-400 text-sm">Loading session…</span>
      </div>
    )
  }

  if (isError || !snapshot) {
    return (
      <div className="fixed inset-0 bg-slate-950 flex flex-col items-center justify-center gap-4">
        <span className="text-slate-300 text-sm">Session not found.</span>
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

  const isSaving = togglePlayed.isPending || setScore.isPending

  return (
    <>
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
        onTogglePlayedGame={(key) => togglePlayed.mutate(key)}
        onSetGameScore={(key, a, b) => setScore.mutate({ key, a, b })}
        title={snapshot.session.title ?? ''}
        date={snapshot.session.date ?? ''}
        sessionStart={snapshot.session.sessionStart}
        slotMinutes={snapshot.session.slotMinutes}
        courtTimes={snapshot.session.courtTimes}
        saving={isSaving}
      />
    </>
  )
}
