import { useState, useEffect } from 'react'
import { useParams, Navigate } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import {
  useGetTournament,
  useConfirmGroups,
  useSetTournamentScore,
  useResetTournament,
  useRegeneratePics,
} from '../queries'
import { getSaveErrorMessage } from '../queries/errors'
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
  const { id = '' } = useParams()
  const [tab, setTab] = useState<Tab>('groups')
  const [localGroups, setLocalGroups] = useState<Record<GroupId, (string | null)[]>>(
    () => ({ A: [null, null, null, null], B: [null, null, null, null], C: [null, null, null, null], D: [null, null, null, null] })
  )
  const [saveError, setSaveError] = useState<string | null>(null)

  // Auto-dismiss error toast after 5 seconds
  useEffect(() => {
    if (!saveError) return
    const timer = setTimeout(() => setSaveError(null), 5000)
    return () => clearTimeout(timer)
  }, [saveError])

  const queryClient = useQueryClient()
  const { data: snapshot, isFetching, refetch } = useGetTournament(id)

  // Halaman ini khusus format classic — narrow dari union snapshot.
  const classic = snapshot && snapshot.format !== 'team' ? snapshot : null

  const handleOpenModal = async () => {
    await queryClient.invalidateQueries({ queryKey: ['tournament', id] })
  }

  const pairs = classic?.pairs ?? INITIAL_PAIRS
  const committedGroups = classic?.groups ?? EMPTY_GROUPS
  const matches = classic?.matches ?? []
  const name = classic?.name ?? 'MAJADU Internal Tournament 2026'

  // Sync localGroups HANYA saat committedGroups benar-benar berubah dari server.
  // Pola "prevCommitted" mencegah localGroups di-revert setiap render saat user
  // sedang edit (bug lama: if committedGroups !== localGroups → setLocalGroups tiap render).
  const [prevCommitted, setPrevCommitted] = useState<Record<GroupId, string[]> | null>(null)
  if (committedGroups !== prevCommitted) {
    setPrevCommitted(committedGroups)
    // Normalisasi: server kirim string[], UI butuh (string | null)[] dengan 4 slot per grup.
    const toSlots = (arr: string[] | undefined): (string | null)[] => {
      const result: (string | null)[] = (arr ?? []).slice(0, 4)
      while (result.length < 4) result.push(null)
      return result
    }
    setLocalGroups({
      A: toSlots(committedGroups.A),
      B: toSlots(committedGroups.B),
      C: toSlots(committedGroups.C),
      D: toSlots(committedGroups.D),
    })
  }
  const date = classic?.date ?? '2026-05-23'

  const groupsFull = GROUP_IDS.every((g) => committedGroups[g].length === 4)

  const addPairToGroup = (pairId: string, groupId: GroupId, slotIndex: number) =>
    setLocalGroups((prev) => {
      const arr = [...prev[groupId]]
      arr[slotIndex] = pairId
      return { ...prev, [groupId]: arr }
    })

  const removePairFromGroup = (pairId: string) =>
    setLocalGroups((prev) => ({
      A: prev.A.map((id) => (id === pairId ? null : id)),
      B: prev.B.map((id) => (id === pairId ? null : id)),
      C: prev.C.map((id) => (id === pairId ? null : id)),
      D: prev.D.map((id) => (id === pairId ? null : id)),
    }))

  const { mutate: confirmGroups, isPending: confirmPending } = useConfirmGroups(id)
  const { mutate: setTournamentScore, isPending: setScorePending } = useSetTournamentScore(id)
  const { mutate: resetTournament, isPending: resetPending } = useResetTournament(id)
  const { mutate: regeneratePics, isPending: regeneratePicsPending } = useRegeneratePics(id)

  const isSaving = confirmPending || setScorePending || resetPending || regeneratePicsPending

  // Tanpa id di URL (mis. akses langsung /tournament) → kembali ke list.
  if (!id) return <Navigate to="/tournaments" replace />

  const tabs: { id: Tab; label: string }[] = [
    { id: 'groups', label: 'Groups' },
    { id: 'bracket', label: 'Bracket' },
    { id: 'standings', label: 'Leaderboard' },
  ]

  const handleTabChange = (newTab: Tab) => setTab(newTab)

  return (
    <div className="flex flex-col gap-0 -mx-3 -mt-4">
      {saveError && (
        <div className="fixed top-4 left-1/2 -translate-x-1/2 z-60 bg-red-900/90 border border-red-700 text-red-200 text-xs px-4 py-2 rounded-lg" role="alert" aria-live="polite">
          {saveError}
        </div>
      )}
      {/* Header */}
      <div className="bg-slate-800 px-4 pt-3 pb-0 border-b border-slate-700">
        <div className="flex items-center gap-2">
          <h2 className="text-[1rem] font-bold text-white leading-tight">{name}</h2>
          {groupsFull && (
            isSaving ? (
              <svg className="animate-spin w-3.5 h-3.5 text-slate-400 shrink-0" viewBox="0 0 24 24" fill="none">
                <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
              </svg>
            ) : (
              <svg className="w-3.5 h-3.5 text-slate-400 shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <polyline points="20 6 9 17 4 12" />
              </svg>
            )
          )}
        </div>
        <p className="text-xs text-slate-400 mt-0.5 mb-3">
          {new Date(date).toLocaleDateString('id-ID', {
            day: 'numeric',
            month: 'long',
            year: 'numeric',
          })}{' '}
          · 16 pairs · 4 groups
        </p>
        <div className="flex">
          {tabs.map((t) => (
            <button
              key={t.id}
              onClick={() => handleTabChange(t.id)}
              className={`flex-1 py-2.5 text-sm font-semibold border-b-2 transition-colors ${
                tab === t.id
                  ? 'text-yellow-400 border-yellow-400'
                  : 'text-slate-400 border-transparent hover:text-slate-200'
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
                  onSetMatchScore={(id, a, b) => setTournamentScore({ matchId: id, scoreA: a, scoreB: b }, {
                    onSuccess: () => setSaveError(null),
                    onError: (error) => setSaveError(getSaveErrorMessage(error)),
                  })}
                  onResetGroups={() => resetTournament({ name, date, pairs }, {
                    onSuccess: () => {
                      setSaveError(null)
                      setLocalGroups(EMPTY_GROUPS)
                    },
                    onError: (error) => setSaveError(getSaveErrorMessage(error)),
                  })}
                  onRegeneratePics={() => regeneratePics(undefined, {
                    onSuccess: () => setSaveError(null),
                    onError: (error) => setSaveError(getSaveErrorMessage(error)),
                  })}
                  isRegeneratingPics={regeneratePicsPending}
                  onOpenModal={handleOpenModal}
                  isFetching={isFetching}
                  refetch={refetch}
                />
              : <GroupAssignment
                  pairs={pairs}
                  groups={localGroups}
                  onAddPairToGroup={addPairToGroup}
                  onRemovePairFromGroup={removePairFromGroup}
                  onConfirmGroups={() => confirmGroups({ localGroups: (Object.fromEntries(GROUP_IDS.map(g => [g, localGroups[g].filter((id): id is string => id !== null)])) as Record<GroupId, string[]>), name, date, pairs }, {
                    onSuccess: () => setSaveError(null),
                    onError: (error) => setSaveError(getSaveErrorMessage(error)),
                  })}
                  isLoading={confirmPending || isFetching}
                />
        )}
        {tab === 'bracket' && (
          <BracketTab
            pairs={pairs}
            matches={matches}
            onSetMatchScore={(id, a, b) => setTournamentScore({ matchId: id, scoreA: a, scoreB: b }, {
              onSuccess: () => setSaveError(null),
              onError: (error) => setSaveError(getSaveErrorMessage(error)),
            })}
            onOpenModal={handleOpenModal}
            isFetching={isFetching}
            refetch={refetch}
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
