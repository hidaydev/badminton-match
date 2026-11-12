// Aliased: this page already keeps its poll state in a `settled` binding.
import { settled as settlePromise } from '../api/settled'
import { Suspense, useMemo, useState } from 'react'
import { useParams } from 'react-router-dom'
import { ApiError } from '../auth/api'
import { POLL_INTERVAL_MS, pollDelayMs } from '../api/retryPolicy'
import { t } from '../i18n'
import { getSharedSession } from '../share/api'
import type { SharedSession } from '../share/api'
import { buildGuestView } from '../share/view'
import { useAsyncEffect } from '../hooks/useAsyncEffect'
import { LoadingState } from '../components/LoadingState'
import { ErrorText } from '../components/ErrorText'
import { safeLazy } from '../legacy/utils/safeLazy'
import type { CourtTime } from '../legacy/types'

// The session body pulls in dnd-kit and the whole summary tree; keep it out of
// the shell bundle a stranger downloads to read one link.
const SummaryModal = safeLazy(() => import('../legacy/components/SummaryModal'))

// A guest payload carries no court times; a stable empty array keeps the
// modal's memo chain quiet.
const NO_COURT_TIMES: CourtTime[] = []

type Settled = {
  code: string
  value: SharedSession | null
  error: 'notFound' | 'failed' | null
}

/**
 * The spectator screen. It renders outside the auth gate, so it must not assume
 * a user, a community or a board: everything it shows comes from the code.
 * The body is the in-app session screen in read-only mode, so a guest reads the
 * same grid, player list and standings a host sees.
 */
export default function SharedSessionPage() {
  const { code = '' } = useParams<{ code: string }>()
  const [settled, setSettled] = useState<Settled | null>(null)

  useAsyncEffect((scope) => {
    if (code === '') return
    let timer: ReturnType<typeof setTimeout> | null = null
    let failures = 0
    let inFlight = false

    const stop = () => {
      if (timer !== null) {
        clearTimeout(timer)
        timer = null
      }
    }
    scope.onCleanup(stop)

    // A hidden tab costs nothing; the next focus refetches anyway.
    const schedule = (delay: number) => {
      stop()
      if (!scope.live || document.hidden) return
      timer = setTimeout(() => { startLoad() }, delay)
    }

    async function load(): Promise<void> {
      // One read at a time: a focus event during a poll joins that read.
      if (!scope.live || inFlight) return
      inFlight = true
      try {
        const value = await getSharedSession(code)
        if (!scope.live) return
        failures = 0
        setSettled({ code, value, error: null })
        schedule(POLL_INTERVAL_MS)
      } catch (problem) {
        if (!scope.live) return
        const missing = problem instanceof ApiError && problem.status === 404
        if (missing) {
          // A rotated or deleted link never comes back — stop polling.
          setSettled({ code, value: null, error: 'notFound' })
          return
        }
        // Keep the games already on screen: a failed refresh should not blank
        // a page the spectator can still read.
        setSettled((previous) =>
          previous !== null && previous.code === code && previous.value !== null
            ? previous
            : { code, value: null, error: 'failed' },
        )
        failures += 1
        schedule(pollDelayMs(failures))
      } finally {
        inFlight = false
      }
    }

    // `load` reports its own failures; this catch guards a throw that would
    // otherwise escape a timer or a focus listener.
    const startLoad = () => {
      settlePromise(load(), 'share read failed')
    }

    const refreshNow = () => {
      if (document.hidden) {
        stop()
        return
      }
      failures = 0
      startLoad()
    }

    const onVisibility = () => {
      if (document.hidden) stop()
      else refreshNow()
    }

    startLoad()
    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('focus', refreshNow)
    scope.onCleanup(() => {
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('focus', refreshNow)
    })
  }, [code])

  const current = settled !== null && settled.code === code ? settled : null
  const loading = code !== '' && current === null
  const session = current?.value ?? null
  const view = useMemo(() => (session === null ? null : buildGuestView(session)), [session])

  return (
    <main className="mx-auto flex w-full max-w-3xl flex-col px-4 py-4">
      <header className="flex items-baseline justify-between gap-3">
        <p className="text-sm font-semibold text-accent">{t('shared.title')}</p>
        {session !== null && (
          <p className="text-xs text-fg-dim">{session.community.name}</p>
        )}
      </header>

      {loading && <LoadingState label={t('app.loading')} rows={1} />}
      {current?.error === 'notFound' && (
        <ErrorText className="mt-4">{t('shared.error.missing')}</ErrorText>
      )}
      {current?.error === 'failed' && (
        <ErrorText className="mt-4">{t('shared.error.load')}</ErrorText>
      )}

      {session !== null && view !== null && (
        <Suspense fallback={<LoadingState label={t('app.loading')} rows={1} />}>
          <SummaryModal
            standalone
            readOnly
            standingsInteractive={false}
            title={session.session.title}
            date={session.session.date}
            sessionStart={view.sessionStart}
            slotMinutes={view.slotMinutes}
            courtTimes={NO_COURT_TIMES}
            scoring={session.scoring ?? undefined}
            result={view.result}
            playerMap={view.playerMap}
            slotsPerCourt={view.slotsPerCourt}
            courtNames={view.courtNames}
            playedGames={view.playedGames}
            gameScores={view.gameScores}
            absentPlayers={view.absentPlayers}
          />
        </Suspense>
      )}
    </main>
  )
}
