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

function GroupLoadingSkeleton() {
  return (
    <div className="space-y-4 animate-pulse">
      {['A', 'B', 'C', 'D'].map((g) => (
        <div key={g} className="bg-slate-800 rounded-xl overflow-hidden">
          <div className="px-4 py-2 flex justify-between items-center border-b border-yellow-500/30">
            <div className="h-4 w-16 bg-slate-700 rounded" />
            <div className="h-3 w-12 bg-slate-700 rounded" />
          </div>
          <div className="divide-y divide-slate-700/50">
            {[0, 1, 2].map((i) => (
              <div key={i} className="flex items-center px-4 py-3 gap-2">
                <div className="flex-1 h-3 bg-slate-700 rounded" />
                <div className="h-6 w-14 bg-slate-700 rounded-md shrink-0" />
                <div className="flex-1 h-3 bg-slate-700 rounded" />
              </div>
            ))}
          </div>
          <div className="border-t border-slate-700 px-4 py-2 space-y-1.5">
            {[0, 1, 2, 3].map((i) => (
              <div key={i} className="h-5 bg-slate-700/60 rounded" />
            ))}
          </div>
        </div>
      ))}
    </div>
  )
}

export default function TournamentPage() {
  const [tab, setTab] = useState<Tab>('groups')
  const name = useTournamentStore((s) => s.name)
  const date = useTournamentStore((s) => s.date)
  const groupsLocked = useTournamentStore((s) => s.groupsLocked)

  const queryClient = useQueryClient()
  const hydrateFromCloud = useTournamentStore((s) => s.hydrateFromCloud)
  const setMatchScore = useTournamentStore((s) => s.setMatchScore)
  const resetGroups = useTournamentStore((s) => s.resetGroups)
  const lockGroups = useTournamentStore((s) => s.lockGroups)
  const matches = useTournamentStore((s) => s.matches)

  const [saveError, setSaveError] = useState<string | null>(null)

  const { data: cloudSnapshot, isFetching } = useQuery<TournamentSnapshot | null>({
    queryKey: ['tournament', TOURNAMENT_ID],
    queryFn: () => getTournament(TOURNAMENT_ID),
    staleTime: 1000 * 60,
    refetchOnWindowFocus: true,
  })

  // Hydrate full store from cloud when cloud has data
  useEffect(() => {
    if (cloudSnapshot?.matches?.length) {
      hydrateFromCloud(cloudSnapshot)
    }
  }, [cloudSnapshot, hydrateFromCloud])

  // Auto-recover: if groups are locked but matches are empty, regenerate from existing groups
  useEffect(() => {
    if (groupsLocked && matches.length === 0) {
      lockGroups()
    }
  }, [groupsLocked, matches.length, lockGroups])

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

  const handleOpenModal = () => {
    queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
  }

  const isSaving = setScoreMutation.isPending || resetMutation.isPending

  const tabs: { id: Tab; label: string }[] = [
    { id: 'groups', label: 'Groups' },
    { id: 'bracket', label: 'Bracket' },
    { id: 'standings', label: 'Standings' },
  ]

  const handleTabChange = (newTab: Tab) => {
    setTab(newTab)
    if (groupsLocked) {
      queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
    }
  }

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
              onClick={() => handleTabChange(t.id)}
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
        {tab === 'groups' && (
          isFetching && cloudSnapshot === undefined
            ? <GroupLoadingSkeleton />
            : groupsLocked
              ? <GroupMatches onSetMatchScore={handleSetMatchScore} onResetGroups={handleResetGroups} onOpenModal={handleOpenModal} isFetching={isFetching} />
              : <GroupAssignment />
        )}
        {tab === 'bracket' && <BracketTab onSetMatchScore={handleSetMatchScore} onOpenModal={handleOpenModal} isFetching={isFetching} />}
        {tab === 'standings' && <StandingsTab />}
      </div>
    </div>
  )
}
