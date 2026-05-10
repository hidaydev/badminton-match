import { useState, useEffect } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { useTournamentStore } from '../store/tournament'
import {
  getTournament,
  publishTournament,
  TOURNAMENT_ID,
  type TournamentSnapshot,
} from '../utils/cloudSync'
import GroupAssignment from '../components/tournament/GroupAssignment'
import GroupMatches from '../components/tournament/GroupMatches'
import BracketTab from '../components/tournament/BracketTab'
import StandingsTab from '../components/tournament/StandingsTab'

type Tab = 'groups' | 'bracket' | 'standings'

export default function TournamentPage() {
  const [tab, setTab] = useState<Tab>('groups')
  const name = useTournamentStore((s) => s.name)
  const date = useTournamentStore((s) => s.date)
  const groupsLocked = useTournamentStore((s) => s.groupsLocked)

  const queryClient = useQueryClient()
  const hydrateFromCloud = useTournamentStore((s) => s.hydrateFromCloud)
  const setMatchScore = useTournamentStore((s) => s.setMatchScore)
  const resetGroups = useTournamentStore((s) => s.resetGroups)

  const [saveError, setSaveError] = useState<string | null>(null)

  const { data: cloudSnapshot } = useQuery<TournamentSnapshot | null>({
    queryKey: ['tournament', TOURNAMENT_ID],
    queryFn: () => getTournament(TOURNAMENT_ID),
    enabled: groupsLocked,
    staleTime: 1000 * 60, // 1 minute
  })

  useEffect(() => {
    if (cloudSnapshot?.matches) {
      hydrateFromCloud(cloudSnapshot.matches)
    }
  }, [cloudSnapshot, hydrateFromCloud])

  const setScoreMutation = useMutation({
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
    },
    mutationFn: async ({ matchId, scoreA, scoreB }: { matchId: string; scoreA: number; scoreB: number }) => {
      setMatchScore(matchId, scoreA, scoreB)
      const state = useTournamentStore.getState()
      const snapshot: TournamentSnapshot = {
        name: state.name,
        date: state.date,
        pairs: state.pairs,
        groups: state.groups,
        groupsLocked: state.groupsLocked,
        matches: state.matches,
      }
      await publishTournament(TOURNAMENT_ID, snapshot)
    },
    onSuccess: () => setSaveError(null),
    onError: () => setSaveError('Failed to save score, please try again'),
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })

  const handleSetMatchScore = (matchId: string, scoreA: number, scoreB: number) => {
    setScoreMutation.mutate({ matchId, scoreA, scoreB })
  }

  const resetMutation = useMutation({
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
    },
    mutationFn: async () => {
      resetGroups()
      const state = useTournamentStore.getState()
      const snapshot: TournamentSnapshot = {
        name: state.name,
        date: state.date,
        pairs: state.pairs,
        groups: state.groups,
        groupsLocked: state.groupsLocked,
        matches: state.matches,
      }
      await publishTournament(TOURNAMENT_ID, snapshot)
    },
    onSuccess: () => setSaveError(null),
    onError: () => setSaveError('Failed to reset, please try again'),
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })

  const handleResetGroups = () => resetMutation.mutate()

  const isSaving = setScoreMutation.isPending || resetMutation.isPending

  const tabs: { id: Tab; label: string }[] = [
    { id: 'groups', label: 'Groups' },
    { id: 'bracket', label: 'Bracket' },
    { id: 'standings', label: 'Standings' },
  ]

  return (
    <div className="flex flex-col gap-0 -mx-3">
      {saveError && (
        <div className="fixed top-4 left-1/2 -translate-x-1/2 z-[60] bg-red-900/90 border border-red-700 text-red-200 text-xs px-4 py-2 rounded-lg">
          {saveError}
        </div>
      )}
      {/* Header */}
      <div className="bg-slate-800 px-4 pt-4 pb-0 border-b border-slate-700">
        <h2 className="text-base font-bold text-white leading-tight">{name}</h2>
        <p className="text-xs text-slate-500 mt-0.5 mb-3">
          {new Date(date).toLocaleDateString('id-ID', {
            day: 'numeric',
            month: 'long',
            year: 'numeric',
          })}{' '}
          · 16 pairs · 4 groups
        </p>
        {groupsLocked && (
          <p className="text-[10px] text-slate-500 mb-2">
            {isSaving ? 'Saving…' : 'Saved'}
          </p>
        )}
        <div className="flex">
          {tabs.map((t) => (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={`flex-1 py-2.5 text-sm font-semibold border-b-2 transition-colors ${
                tab === t.id
                  ? 'text-yellow-400 border-yellow-400'
                  : 'text-slate-500 border-transparent hover:text-slate-300'
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>
      </div>

      {/* Tab content */}
      <div className="px-3 pt-4 pb-8">
        {tab === 'groups' && (groupsLocked ? <GroupMatches onSetMatchScore={handleSetMatchScore} onResetGroups={handleResetGroups} /> : <GroupAssignment />)}
        {tab === 'bracket' && <BracketTab onSetMatchScore={handleSetMatchScore} />}
        {tab === 'standings' && <StandingsTab />}
      </div>
    </div>
  )
}
