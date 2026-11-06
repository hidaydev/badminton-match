import { useState, useEffect } from 'react'
import { Link, useParams, useNavigate, useLegacySlug } from '../router'
import { useQueryClient } from '@tanstack/react-query'
import {
  useGetSession,
  useSessionRealtime,
  useSetSessionLock,
  useTogglePlayed,
  useSetScore,
  useSwapPlayers,
  useSetAbsent,
  useSetGameSkipped,
  useReplacePlayer,
  useSwapSlots,
  useSwapTeams,
  useChangePlayer,
  type CloudSnapshot,
} from '../queries'
import { registerPlayer } from '../queries/endpoints'
import { selectSlotsPerCourt } from '../store/selectors'
import { collectAmbiguousBaseNames } from '../utils/nameParser'
import { AmbiguousNamesProvider, combineAmbiguous, useAmbiguousNames } from '../context/AmbiguousNamesContext'
import type { GeneratorResult } from '../generator'
import type { SlotSwapTarget } from '../utils/slotSwap'
import type { TeamSwapTarget, SwapTarget } from '../utils/swap'
import SummaryModal from '../components/SummaryModal'
import ErrorBanner from '../components/ErrorBanner'
import { useAdmin } from '../context/AdminContext'
import { useLastSession } from '../hooks/useLastSession'
import { useAutoDismiss, mutationToastHandlers } from '../hooks/useAutoDismiss'
import { getSaveErrorMessage } from '../queries/errors'
import { communityQueryKey } from '../queries/keys'
import { communityHref } from '../../routes.manifest'
import { t } from '../../i18n'

export default function SharedSessionPage() {
  const { sessionId } = useParams<{ sessionId: string }>()
  const slug = useLegacySlug()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [saveError, setSaveError] = useState<string | null>(null)
  // Hook wajib sebelum early return di bawah.
  const globalAmbiguous = useAmbiguousNames()
  // The server only accepts session writes from a host or admin, so a member
  // gets the same screen without any edit affordance.
  const { isAdmin } = useAdmin()
  const canEdit = isAdmin

  // Auto-dismiss error toast after 3 seconds (keputusan poin 4)
  useAutoDismiss(saveError, setSaveError, 3000)

  const { mutate: togglePlayed, isPending: togglePlayedPending } = useTogglePlayed(sessionId!)
  const { mutate: setScore, isPending: setScorePending } = useSetScore(sessionId!)
  const { mutate: swapPlayers, isPending: swapPlayersPending } = useSwapPlayers(sessionId!)
  const { mutate: setAbsent, isPending: setAbsentPending } = useSetAbsent(sessionId!)
  const { mutateAsync: setSkippedAsync, isPending: setSkippedPending } = useSetGameSkipped(sessionId!)
  const { mutate: replacePlayer, isPending: replacePlayerPending } = useReplacePlayer(sessionId!)
  const { mutate: swapSlots, isPending: swapSlotsPending } = useSwapSlots(sessionId!)
  const { mutate: swapTeams, isPending: swapTeamsPending } = useSwapTeams(sessionId!)
  const { mutate: changePlayer, isPending: changePlayerPending } = useChangePlayer(sessionId!)
  const { mutateAsync: setSessionLocked, isPending: lockPending } = useSetSessionLock(sessionId!)

  const isSaving = togglePlayedPending || setScorePending || swapPlayersPending || setAbsentPending || setSkippedPending || replacePlayerPending || swapSlotsPending || swapTeamsPending || changePlayerPending

  const { connected: realtimeConnected, reconnecting: realtimeReconnecting } = useSessionRealtime(sessionId)

  const { data: snapshot, isLoading, isError, refetch, isFetching } = useGetSession(sessionId, {
    refetchInterval: realtimeConnected ? false : isSaving ? false : 5_000,
    refetchOnWindowFocus: true,
  })

  const { save } = useLastSession()

  useEffect(() => {
    if (!snapshot || !sessionId) return
    save({
      id: sessionId,
      slug,
      title: snapshot.session.title,
      date: snapshot.session.date,
      playerCount: snapshot.players.length,
      totalGames: snapshot.schedule.length,
      locked: !!snapshot.session.locked,
    })
  }, [save, sessionId, slug, snapshot])

  const header = (
    <header className="border-b border-border-subtle bg-surface sticky top-0 z-10 pt-[env(safe-area-inset-top)]">
      <div className="max-w-3xl mx-auto px-3 py-2.5 flex flex-wrap items-center gap-2">
        <button onClick={() => navigate(-1)} className="p-1.5 -ml-1.5 rounded-lg text-fg-dim hover:text-fg active:scale-90 transition-all shrink-0" aria-label={t('shell.back')}>
          <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <path d="M15 18l-6-6 6-6"/>
          </svg>
        </button>
        <Link to="/" className="flex items-center gap-2">
          <img src="/logo-192.png" alt="" className="w-6 h-6 shrink-0 object-contain" />
          <h1 className="text-sm font-bold text-fg tracking-tight">MAJADU</h1>
        </Link>
        {/* The logo also resolves to the community; this labelled link makes
            the way back explicit on a screen outside HomeLayout. */}
        <Link
          to={communityHref(slug, '/')}
          className="ml-auto inline-flex min-h-11 shrink-0 items-center whitespace-nowrap rounded-lg px-2 text-xs text-fg-dim hover:text-fg focus-visible:ring-2 focus-visible:ring-accent"
        >
          {t('session.backToCommunity')}
        </Link>
        {realtimeReconnecting && (
          <span className="text-xs text-amber-400 animate-pulse">⟳ Reconnecting…</span>
        )}
      </div>
    </header>
  )

  if (isLoading) {
    return (
      <div className="min-h-screen bg-ground text-fg flex flex-col">
        {header}
        <div className="flex-1 flex items-center justify-center">
          <span className="text-slate-400 text-sm">Loading session…</span>
        </div>
      </div>
    )
  }

  if (isError || !snapshot) {
    return (
      <div className="min-h-screen bg-ground text-fg flex flex-col">
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

  const playerMap = snapshot ? new Map(snapshot.players.map((p) => [p.id, p])) : new Map()
  // Gabung dengan set global: nama ambigu di populasi tetap dapat badge walau
  // di sesi ini hanya muncul sekali.
  const ambiguousNames = combineAmbiguous(
    globalAmbiguous,
    collectAmbiguousBaseNames((snapshot?.players ?? []).map((p) => p.name)),
  )

  const result: GeneratorResult | null = snapshot ? {
    schedule: snapshot.schedule,
    playCount: {},
    sitCount: {},
    partnerWith: {},
    facedBy: {},
    unplacedFixMatches: [],
  } : null

  return (
    <AmbiguousNamesProvider value={ambiguousNames}>
    <main className="min-h-screen bg-ground text-fg flex flex-col">
      {header}
      {saveError && <ErrorBanner message={saveError} />}
      <SummaryModal
        result={result!}
        playerMap={playerMap}
        slotsPerCourt={selectSlotsPerCourt(snapshot.session)}
        courtNames={snapshot.session.courtNames ?? []}
        playedGames={snapshot.playedGames}
        gameScores={snapshot.gameScores}
        scoring={snapshot.session.scoring}
        onTogglePlayedGame={(key) => {
          const current = queryClient.getQueryData<CloudSnapshot>(communityQueryKey('session', sessionId))
          const willBePlayed = !current?.playedGames.includes(key)
          togglePlayed({ key, nextPlayed: willBePlayed }, mutationToastHandlers(setSaveError))
        }}
        onSetGameScore={(key, sets) => setScore({ key, sets }, mutationToastHandlers(setSaveError))}
        title={snapshot.session.title ?? ''}
        date={snapshot.session.date ?? ''}
        sessionStart={snapshot.session.sessionStart}
        slotMinutes={snapshot.session.slotMinutes}
        courtTimes={snapshot.session.courtTimes}
        saving={isSaving}
        onSwapPlayers={(t1, t2) => swapPlayers({ t1, t2 }, mutationToastHandlers(setSaveError))}
        absentPlayers={snapshot.absentPlayers ?? []}
        skippedPlayers={snapshot.skippedPlayers ?? {}}
        onSetAbsent={(nextAbsent) => setAbsent({ nextAbsent }, mutationToastHandlers(setSaveError))}
        onSetGameSkipped={async (key, playerIds) => {
          // Resolves per game so the confirm handler can stop on the first failure.
          await setSkippedAsync({ key, playerIds }, mutationToastHandlers(setSaveError))
        }}
        onReplacePlayer={async (playerId, newName) => {
          try {
            await registerPlayer(newName)
          } catch (err) {
            setSaveError(getSaveErrorMessage(err))
            return
          }
          replacePlayer({ playerId, newName }, mutationToastHandlers(setSaveError))
        }}
        onSwapSlots={(g1: SlotSwapTarget, g2: SlotSwapTarget) => swapSlots({ g1, g2 }, mutationToastHandlers(setSaveError))}
        onSwapTeams={(t1: TeamSwapTarget, t2: TeamSwapTarget) => swapTeams({ t1, t2 }, mutationToastHandlers(setSaveError))}
        onChangePlayer={async (target: SwapTarget, newName: string) => {
          try {
            // Check if typed name matches an existing player in the snapshot
            const existingPlayer = snapshot?.players.find(
              p => p.name.trim().toLowerCase() === newName.trim().toLowerCase()
            )
            const playerId = existingPlayer
              ? existingPlayer.id  // Use existing UUID — don't call registerPlayer
              : (await registerPlayer(newName)).playerId
            changePlayer({ target, newName: playerId, playerName: newName }, mutationToastHandlers(setSaveError))
          } catch (err) {
            setSaveError(getSaveErrorMessage(err))
          }
        }}
        standalone
        shareSessionId={canEdit ? sessionId : undefined}
        onRefetch={() => refetch()}
        isRefetching={isFetching}
        locked={!!snapshot?.session?.locked}
        readOnly={!canEdit || !!snapshot?.session?.locked}
        onSetLocked={canEdit ? async (nextLocked) => {
          const version = snapshot.version
          if (version == null) {
            setSaveError('Session version is not loaded. Reload and try again.')
            return
          }
          try {
            await setSessionLocked({ locked: nextLocked, version })
          } catch (err) {
            setSaveError(getSaveErrorMessage(err))
          }
        } : undefined}
        lockBusy={lockPending}
      />
    </main>
    </AmbiguousNamesProvider>
  )
}
