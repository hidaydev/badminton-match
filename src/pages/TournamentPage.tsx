import { useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import {
  getTournament,
  publishTournament,
  TOURNAMENT_ID,
  type TournamentSnapshot,
} from '../utils/cloudSync'
import {
  generateGroupMatches,
  initKnockoutMatches,
  propagateBracket,
} from '../utils/tournament'
import type { GroupId, TournamentPair } from '../utils/tournament'
import GroupAssignment from '../components/tournament/GroupAssignment'
import GroupMatches from '../components/tournament/GroupMatches'
import BracketTab from '../components/tournament/BracketTab'
import StandingsTab from '../components/tournament/StandingsTab'

type Tab = 'groups' | 'bracket' | 'standings'

const GROUP_IDS: GroupId[] = ['A', 'B', 'C', 'D']

const INITIAL_PAIRS: TournamentPair[] = [
  { id: 'p1',  name: 'Dwi & Ismet' },
  { id: 'p2',  name: 'Vina & Fredi' },
  { id: 'p3',  name: 'Iky & Raihan' },
  { id: 'p4',  name: 'Azzam & Zainal' },
  { id: 'p5',  name: 'Dendi & Maul' },
  { id: 'p6',  name: 'Euis & Akid' },
  { id: 'p7',  name: 'Anas & Nindya' },
  { id: 'p8',  name: 'Faiz & Dimas' },
  { id: 'p9',  name: 'Fahmi & Lulud' },
  { id: 'p10', name: 'Agha & Lita' },
  { id: 'p11', name: 'Rakha & Visi' },
  { id: 'p12', name: 'Fakhri & Novian' },
  { id: 'p13', name: 'Hidayat & Zaid' },
  { id: 'p14', name: 'Boby & Andri' },
  { id: 'p15', name: 'Rudi & Ega' },
  { id: 'p16', name: 'Bowo & Didik' },
]

const EMPTY_GROUPS: Record<GroupId, string[]> = { A: [], B: [], C: [], D: [] }

function GroupLoadingSkeleton() {
  return (
    <div className="space-y-4 animate-pulse">
      <div className="flex justify-end">
        <div className="h-4 w-20 bg-slate-700 rounded" />
      </div>
      {['A', 'B', 'C', 'D'].map((g) => (
        <div key={g} className="bg-slate-800 rounded-xl overflow-hidden">
          <div className="px-4 py-2 flex justify-between items-center border-b border-yellow-500/30">
            <div className="h-4 w-16 bg-slate-700 rounded" />
            <div className="h-3 w-12 bg-slate-700 rounded" />
          </div>
          <div className="divide-y divide-slate-700/50">
            {[0, 1, 2, 3, 4, 5].map((i) => (
              <div key={i} className="flex items-center px-4 py-3 gap-2">
                <div className="flex-1 h-4 bg-slate-700 rounded" />
                <div className="h-6 w-14 bg-slate-700 rounded-md shrink-0" />
                <div className="flex-1 h-4 bg-slate-700 rounded" />
              </div>
            ))}
          </div>
          <div className="border-t border-slate-700 px-4 py-2 space-y-1">
            <div className="h-3 w-full bg-slate-700/40 rounded mb-1" />
            {[0, 1, 2, 3].map((i) => (
              <div key={i} className="h-6 bg-slate-700/60 rounded" />
            ))}
          </div>
        </div>
      ))}
    </div>
  )
}

export default function TournamentPage() {
  const [tab, setTab] = useState<Tab>('groups')
  const [localGroups, setLocalGroups] = useState<Record<GroupId, string[]>>(EMPTY_GROUPS)
  const [saveError, setSaveError] = useState<string | null>(null)

  const queryClient = useQueryClient()

  const { data: snapshot, isFetching } = useQuery<TournamentSnapshot | null>({
    queryKey: ['tournament', TOURNAMENT_ID],
    queryFn: () => getTournament(TOURNAMENT_ID),
    staleTime: 1000 * 60,
    refetchOnWindowFocus: true,
  })

  const pairs = snapshot?.pairs ?? INITIAL_PAIRS
  const committedGroups = snapshot?.groups ?? EMPTY_GROUPS
  const matches = snapshot?.matches ?? []
  const name = snapshot?.name ?? 'MAJADU Internal Tournament 2026'
  const date = snapshot?.date ?? '2026-05-23'

  const groupsFull = GROUP_IDS.every((g) => committedGroups[g].length === 4)

  const addPairToGroup = (pairId: string, groupId: GroupId) =>
    setLocalGroups((prev) => ({ ...prev, [groupId]: [...prev[groupId], pairId] }))

  const removePairFromGroup = (pairId: string) =>
    setLocalGroups((prev) => ({
      A: prev.A.filter((id) => id !== pairId),
      B: prev.B.filter((id) => id !== pairId),
      C: prev.C.filter((id) => id !== pairId),
      D: prev.D.filter((id) => id !== pairId),
    }))

  const confirmMutation = useMutation({
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
    },
    mutationFn: async () => {
      const groupMatches = GROUP_IDS.flatMap((g) => generateGroupMatches(g, localGroups[g]))
      const allMatches = [...groupMatches, ...initKnockoutMatches()]
      const newMatches = propagateBracket(allMatches, localGroups, pairs)
      await publishTournament(TOURNAMENT_ID, { name, date, pairs, groups: localGroups, matches: newMatches })
    },
    onSuccess: () => setSaveError(null),
    onError: () => setSaveError('Failed to save groups, please try again'),
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })

  const setScoreMutation = useMutation({
    onMutate: async ({ matchId, scoreA, scoreB }: { matchId: string; scoreA: number; scoreB: number }) => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
      const previous = queryClient.getQueryData<TournamentSnapshot | null>(['tournament', TOURNAMENT_ID])
      if (previous) {
        const updated = previous.matches.map((m) => m.id === matchId ? { ...m, scoreA, scoreB } : m)
        const propagated = propagateBracket(updated, previous.groups, previous.pairs)
        queryClient.setQueryData(['tournament', TOURNAMENT_ID], { ...previous, matches: propagated })
      }
      return { previous }
    },
    mutationFn: async (_: { matchId: string; scoreA: number; scoreB: number }) => {
      const current = queryClient.getQueryData<TournamentSnapshot | null>(['tournament', TOURNAMENT_ID])
      if (!current) return
      await publishTournament(TOURNAMENT_ID, current)
    },
    onSuccess: () => setSaveError(null),
    onError: (_err, _vars, context) => {
      queryClient.setQueryData(['tournament', TOURNAMENT_ID], context?.previous)
      setSaveError('Failed to save score, please try again')
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })

  const resetMutation = useMutation({
    onMutate: async () => {
      await queryClient.cancelQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
    },
    mutationFn: async () => {
      await publishTournament(TOURNAMENT_ID, { name, date, pairs, groups: EMPTY_GROUPS, matches: [] })
    },
    onSuccess: () => {
      setSaveError(null)
      setLocalGroups(EMPTY_GROUPS)
    },
    onError: () => setSaveError('Failed to reset, please try again'),
    onSettled: () => queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] }),
  })

  const handleOpenModal = () => {
    queryClient.invalidateQueries({ queryKey: ['tournament', TOURNAMENT_ID] })
  }

  const isSaving = confirmMutation.isPending || setScoreMutation.isPending || resetMutation.isPending

  const tabs: { id: Tab; label: string }[] = [
    { id: 'groups', label: 'Groups' },
    { id: 'bracket', label: 'Bracket' },
    { id: 'standings', label: 'Standings' },
  ]

  const handleTabChange = (newTab: Tab) => {
    setTab(newTab)
    if (groupsFull) {
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
        {groupsFull && (
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
          isFetching && snapshot === undefined
            ? <GroupLoadingSkeleton />
            : groupsFull
              ? <GroupMatches
                  pairs={pairs}
                  groups={committedGroups}
                  matches={matches}
                  onSetMatchScore={(id, a, b) => setScoreMutation.mutate({ matchId: id, scoreA: a, scoreB: b })}
                  onResetGroups={() => resetMutation.mutate()}
                  onOpenModal={handleOpenModal}
                  isFetching={isFetching}
                />
              : <GroupAssignment
                  pairs={pairs}
                  groups={localGroups}
                  onAddPairToGroup={addPairToGroup}
                  onRemovePairFromGroup={removePairFromGroup}
                  onConfirmGroups={() => confirmMutation.mutate()}
                />
        )}
        {tab === 'bracket' && (
          <BracketTab
            pairs={pairs}
            matches={matches}
            onSetMatchScore={(id, a, b) => setScoreMutation.mutate({ matchId: id, scoreA: a, scoreB: b })}
            onOpenModal={handleOpenModal}
            isFetching={isFetching}
          />
        )}
        {tab === 'standings' && (
          <StandingsTab
            pairs={pairs}
            groups={committedGroups}
            matches={matches}
          />
        )}
      </div>
    </div>
  )
}
