import { useState } from 'react'
import { useParams, Navigate, Link } from '../router'
import { useQueryClient } from '@tanstack/react-query'
import {
  useGetTournament,
  useConfirmGroups,
  useSetTournamentScore,
} from '../queries'
import { communityQueryKey } from '../queries/keys'
import { GROUP_IDS, EMPTY_GROUPS, type GroupId } from '../utils/tournament'
import { todayLocal } from '../utils/time'
import { formatLongDate } from '../../utils/day'
import { t } from '../../i18n'
import { TabBar, tabId, tabPanelId } from '../../components/TabBar'
import { useAutoDismiss, mutationToastHandlers } from '../hooks/useAutoDismiss'
import { useAdmin } from '../context/AdminContext'
import ErrorBanner from '../components/ErrorBanner'
import GroupAssignment from '../components/tournament/GroupAssignment'
import GroupMatches from '../components/tournament/GroupMatches'
import BracketTab from '../components/tournament/BracketTab'
import StandingsTab from '../components/tournament/StandingsTab'

type Tab = 'groups' | 'bracket' | 'standings'

function GroupLoadingSkeleton() {
  return (
    <div className="space-y-4 animate-pulse">
      <div className="flex justify-end">
        <div className="h-4 w-20 bg-elevated rounded" />
      </div>
      {GROUP_IDS.map((g) => (
        <div key={g} className="bg-surface border border-border-subtle rounded-xl overflow-hidden">
          <div className="px-4 py-2 flex justify-between items-center border-b border-border-subtle">
            <div className="h-4 w-16 bg-elevated rounded" />
            <div className="h-3 w-12 bg-elevated rounded" />
          </div>
          <div className="divide-y divide-border-subtle">
            {[0, 1, 2, 3, 4, 5].map((i) => (
              <div key={i} className="flex items-center px-4 py-3 gap-2">
                <div className="flex-1 h-4 bg-elevated rounded" />
                <div className="h-6 w-14 bg-elevated rounded-lg shrink-0" />
                <div className="flex-1 h-4 bg-elevated rounded" />
              </div>
            ))}
          </div>
          <div className="border-t border-border-subtle px-4 py-2 space-y-1">
            <div className="h-3 w-full bg-elevated/40 rounded mb-1" />
            {[0, 1, 2, 3].map((i) => (
              <div key={i} className="h-6 bg-elevated/60 rounded" />
            ))}
          </div>
        </div>
      ))}
    </div>
  )
}

export default function TournamentPage() {
  const { id = '' } = useParams()
  // The server only accepts tournament writes from a host or admin, so a member
  // gets the same screen with the score and group editors turned off.
  const { isAdmin } = useAdmin()
  const canEdit = isAdmin
  const [tab, setTab] = useState<Tab>('groups')
  const [localGroups, setLocalGroups] = useState<Record<GroupId, (string | null)[]>>(
    () => ({ A: [null, null, null, null], B: [null, null, null, null], C: [null, null, null, null], D: [null, null, null, null] })
  )
  const [saveError, setSaveError] = useState<string | null>(null)

  // Auto-dismiss error toast after 5 seconds
  useAutoDismiss(saveError, setSaveError, 5000)

  const queryClient = useQueryClient()
  const { data: snapshot, isFetching, refetch } = useGetTournament(id)

  // Halaman ini khusus format classic — narrow dari union snapshot.
  const classic = snapshot && snapshot.format !== 'team' ? snapshot : null

  const handleOpenModal = async () => {
    await queryClient.invalidateQueries({ queryKey: communityQueryKey('tournament', id) })
  }

  const pairs = classic?.pairs ?? []
  const committedGroups = classic?.groups ?? EMPTY_GROUPS
  const matches = classic?.matches ?? []
  const name = classic?.name ?? ''
  const groupCount = GROUP_IDS.filter((g) => committedGroups[g].length > 0).length

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
  const date = classic?.date ?? todayLocal()

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

  const isSaving = confirmPending || setScorePending

  // Tanpa id di URL (mis. akses langsung /tournament) → kembali ke list.
  if (!id) return <Navigate to="/tournaments" replace />
  // A 404 comes back as `null`, not an empty snapshot: show that instead of a
  // fabricated bracket with today's date.
  if (snapshot === null) {
    return (
      <div className="flex flex-col items-center gap-3 px-4 py-16 text-center">
        <p className="text-sm text-fg-dim">{t('tournaments.error.notFound')}</p>
        <Link to="/tournaments" className="text-sm font-semibold text-accent">
          {t('tournaments.backToList')}
        </Link>
      </div>
    )
  }

  const tabs: { id: Tab; label: string }[] = [
    { id: 'groups', label: t('tournament.tab.groups') },
    { id: 'bracket', label: t('tournament.tab.bracket') },
    { id: 'standings', label: t('tournament.tab.standings') },
  ]

  const handleTabChange = (newTab: Tab) => setTab(newTab)

  return (
    <div className="flex flex-col gap-0 -mx-3 -mt-4">
      {saveError && <ErrorBanner message={saveError} />}
      {/* Header */}
      <div className="bg-surface px-4 pt-3 pb-0 border-b border-border">
        <div className="flex items-center gap-2">
          <h1 className="text-[1rem] font-bold text-fg leading-tight">{name}</h1>
          {groupsFull && (
            isSaving ? (
              <svg className="animate-spin w-3.5 h-3.5 text-fg-dim shrink-0" viewBox="0 0 24 24" fill="none">
                <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
              </svg>
            ) : (
              <svg className="w-3.5 h-3.5 text-fg-dim shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                <polyline points="20 6 9 17 4 12" />
              </svg>
            )
          )}
        </div>
        {snapshot && (
          <p className="text-xs text-fg-dim mt-0.5 mb-3">
            {formatLongDate(date, false)} · {t(pairs.length === 1 ? 'classic.header.pair' : 'classic.header.pairs', { count: pairs.length })} · {t(groupCount === 1 ? 'classic.header.group' : 'classic.header.groups', { count: groupCount })}
          </p>
        )}
        <TabBar
          items={tabs}
          value={tab}
          onChange={handleTabChange}
          label={t('tournament.tabs')}
          idPrefix="tournament-tabs"
          className="flex"
          tabClassName={(_item, selected) =>
            `flex-1 py-2.5 text-sm font-semibold border-b-2 transition-colors ${
              selected
                ? 'text-accent border-accent'
                : 'text-fg-dim border-transparent hover:text-fg'
            }`
          }
        />
      </div>

      {/* Tab content */}
      <div
        id={tabPanelId('tournament-tabs')}
        role="tabpanel"
        aria-labelledby={tabId('tournament-tabs', tab)}
        className="px-3 pt-4 pb-8"
      >
        {tab === 'groups' && (
          isFetching && snapshot === undefined
            ? <GroupLoadingSkeleton />
            : groupsFull
              ? <GroupMatches
                  pairs={pairs}
                  groups={committedGroups}
                  matches={matches}
                  canEdit={canEdit}
                  onSetMatchScore={(id, a, b) => setTournamentScore({ matchId: id, scoreA: a, scoreB: b }, mutationToastHandlers(setSaveError))}
                  onOpenModal={handleOpenModal}
                  isFetching={isFetching}
                  refetch={refetch}
                />
              : canEdit
                ? <GroupAssignment
                    pairs={pairs}
                    groups={localGroups}
                    onAddPairToGroup={addPairToGroup}
                    onRemovePairFromGroup={removePairFromGroup}
                    onConfirmGroups={() => confirmGroups({ localGroups: (Object.fromEntries(GROUP_IDS.map(g => [g, localGroups[g].filter((id): id is string => id !== null)])) as Record<GroupId, string[]>), name, date, pairs }, mutationToastHandlers(setSaveError))}
                    isLoading={confirmPending || isFetching}
                  />
                : (
                  <p className="text-fg-dim text-sm text-center py-16">
                    {t('legacy.groupsNotDrawn')}
                  </p>
                )
        )}
        {tab === 'bracket' && (
          <BracketTab
            pairs={pairs}
            matches={matches}
            canEdit={canEdit}
            onSetMatchScore={(id, a, b) => setTournamentScore({ matchId: id, scoreA: a, scoreB: b }, mutationToastHandlers(setSaveError))}
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
