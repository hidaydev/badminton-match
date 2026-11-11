import { useId, useState } from 'react'
import { useParams } from 'react-router-dom'
import { ApiError } from '../auth/api'
import { POLL_INTERVAL_MS, pollDelayMs } from '../api/retryPolicy'
import { t } from '../i18n'
import type { MessageKey } from '../i18n/en'
import { formatCompactDate } from '../utils/day'
import { ordinal } from '../legacy/utils/ordinal'
import { describeSets } from '../legacy/utils/scoring'
import { computeDiff, initTallyRow, standardStandingSort, tallyMatch } from '../legacy/utils/tally'
import { getSharedSession } from '../share/api'
import type { SharedGame, SharedSession, SharedStanding } from '../share/api'
import { useAsyncEffect } from '../hooks/useAsyncEffect'
import { LoadingState } from '../components/LoadingState'
import { ErrorText } from '../components/ErrorText'
import { StandingsTable } from '../components/StandingsTable'
import { EmptyState } from '../components/EmptyState'
import { Tabs } from '../components/Tabs'

type Settled = {
  code: string
  value: SharedSession | null
  error: 'notFound' | 'failed' | null
}

/** The share payload sends a machine value; the screen shows a word. */
const STATUS_LABELS: Record<string, MessageKey> = {
  draft: 'shared.status.draft',
  locked: 'shared.status.locked',
}

function statusLabel(status: string): string {
  const key = STATUS_LABELS[status]
  return key === undefined ? status : t(key)
}

type Tab = 'games' | 'standings'

const GAME_STATUS: Record<string, MessageKey> = {
  played: 'shared.gameStatus.played',
  cancelled: 'shared.gameStatus.cancelled',
  scheduled: 'shared.gameStatus.scheduled',
}

/**
 * Same tally as `computeStandings` (the session screen and the Instagram
 * export): wins, then point difference, then points for, then the name. The
 * server sends the finalized rows; this only covers a payload from an older
 * build that has no standings yet.
 */
function standingsFromGames(games: SharedGame[]): SharedStanding[] {
  const rows = new Map<string, SharedStanding>()
  const tally = (name: string, pointsFor: number, pointsAgainst: number, won: boolean) => {
    const row = rows.get(name) ?? { name, ...initTallyRow() }
    tallyMatch(row, pointsFor, pointsAgainst, won)
    rows.set(name, row)
  }
  for (const game of games) {
    if (game.status !== 'played' || game.scoreA === null || game.scoreB === null) continue
    if (game.sideA.length === 0 || game.sideB.length === 0) continue
    // The winner comes from the sets; total points only break board ties.
    const aWon = game.winner === 'A' || (game.winner === undefined && game.scoreA > game.scoreB)
    for (const name of game.sideA) tally(name, game.scoreA, game.scoreB, aWon)
    for (const name of game.sideB) tally(name, game.scoreB, game.scoreA, !aWon)
  }
  for (const row of rows.values()) computeDiff(row)
  return [...rows.values()].sort(
    (a, b) => standardStandingSort(a, b) || a.name.localeCompare(b.name),
  )
}

/**
 * The spectator screen. It renders outside the auth gate, so it must not assume
 * a user, a community or a board: everything it shows comes from the code.
 * The layout follows the in-app session screen: one tab bar, then either the
 * games or the standings, never both stacked.
 */
export default function SharedSessionPage() {
  const { code = '' } = useParams<{ code: string }>()
  const [settled, setSettled] = useState<Settled | null>(null)
  const [tab, setTab] = useState<Tab>('games')
  const panelId = useId()

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
      timer = setTimeout(() => { void load() }, delay)
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

    const refreshNow = () => {
      if (document.hidden) {
        stop()
        return
      }
      failures = 0
      void load()
    }

    const onVisibility = () => {
      if (document.hidden) stop()
      else refreshNow()
    }

    void load()
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
  const standings =
    session === null
      ? []
      : session.standings?.items ?? standingsFromGames(session.games)

  const rounds: { round: number; games: SharedGame[] }[] = []
  for (const game of session?.games ?? []) {
    const last = rounds[rounds.length - 1]
    if (last !== undefined && last.round === game.round) last.games.push(game)
    else rounds.push({ round: game.round, games: [game] })
  }

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

      {session !== null && (
        <>
          <h1 className="mt-2 text-xl font-bold text-fg sm:text-2xl">
            {session.session.title}
          </h1>
          <p className="mt-1 text-xs text-fg-dim">
            <time dateTime={session.session.date}>
              {formatCompactDate(session.session.date)}
            </time>
            {' · '}
            {statusLabel(session.session.status)}
            {session.scoring && (
              <>
                {' · '}
                {session.scoring.label}
              </>
            )}
          </p>

          <div className="mt-4 flex flex-wrap items-center gap-2 border-b border-slate-800 pb-3">
            <Tabs
              items={[
                { id: 'games', label: t('session.games') },
                { id: 'standings', label: t('session.standings') },
              ]}
              value={tab}
              onChange={(id) => setTab(id as Tab)}
              panelId={panelId}
              label={t('shared.tabs')}
              tabClassName={(active) =>
                `inline-flex min-h-11 items-center text-xs font-semibold px-4 rounded-lg transition-colors ${
                  active
                    ? 'bg-indigo-900/60 border border-indigo-700 text-indigo-300'
                    : 'text-slate-400 hover:text-slate-200'
                }`
              }
            />
            {rounds.length > 0 && (
              <span className="text-xs text-slate-400">
                {t('shared.gamesCount', { games: session.games.length })}
              </span>
            )}
          </div>

          <div
            // `Tabs` names each button `${panelId}-${id}` and points every tab
            // at `panelId`, so the panel is the id itself and its label is the
            // selected tab's id. The `tabId`/`tabPanelId` helpers in `TabBar`
            // use a different scheme and left both references dangling.
            id={panelId}
            role="tabpanel"
            aria-labelledby={`${panelId}-${tab}`}
            className="mt-3 flex flex-col"
          >
            {tab === 'games' &&
              (session.games.length === 0 ? (
                <EmptyState title={t('session.games.empty')} />
              ) : (
                <div className="flex flex-col divide-y divide-slate-800">
                  {rounds.map((entry) => (
                    <div key={entry.round} className="flex items-start gap-3 py-3">
                      <span className="w-5 shrink-0 pt-1.5 text-xs font-bold text-slate-400">
                        #{entry.round + 1}
                      </span>
                      <div className="flex flex-1 flex-col gap-2">
                        {entry.games.map((game) => {
                          const played =
                            game.status === 'played' &&
                            game.scoreA !== null &&
                            game.scoreB !== null
                          const sets = game.sets ?? []
                          const headline = sets.length > 0
                            ? describeSets(sets)
                            : `${game.scoreA}–${game.scoreB}`
                          const tally = sets.length > 1
                            ? `${game.setsWonA ?? 0}–${game.setsWonB ?? 0}`
                            : null
                          return (
                            <div
                              key={game.id}
                              className={`flex items-center gap-2 rounded-xl border border-slate-800 px-2.5 py-2 ${played ? 'bg-slate-800/30' : 'bg-slate-900/40'}`}
                            >
                              <span className="w-7 shrink-0 text-[10px] font-semibold text-slate-400">
                                {game.round + 1}.{game.court + 1}
                              </span>
                              <div
                                className="grid flex-1 min-w-0 items-center gap-1"
                                style={{ gridTemplateColumns: '1fr 16px 1fr' }}
                              >
                                <span className="min-w-0 text-xs font-medium text-slate-200">
                                  {game.sideA.length === 0
                                    ? t('session.side.empty')
                                    : game.sideA.join(' & ')}
                                </span>
                                <span className="text-center text-xs font-bold text-slate-400">
                                  {t('shared.versus')}
                                </span>
                                <span className="min-w-0 text-xs font-medium text-slate-200">
                                  {game.sideB.length === 0
                                    ? t('session.side.empty')
                                    : game.sideB.join(' & ')}
                                </span>
                              </div>
                              {played ? (
                                <span className="shrink-0 whitespace-nowrap text-right">
                                  <span className="block text-[11px] font-bold tabular-nums text-emerald-300">
                                    {headline}
                                  </span>
                                  {tally !== null && (
                                    <span className="block text-[11px] text-slate-400">
                                      {tally}
                                    </span>
                                  )}
                                </span>
                              ) : (
                                <span className="shrink-0 whitespace-nowrap text-[10px] text-slate-400">
                                  {t(GAME_STATUS[game.status] ?? GAME_STATUS.scheduled)}
                                </span>
                              )}
                            </div>
                          )
                        })}
                      </div>
                    </div>
                  ))}
                </div>
              ))}

            {tab === 'standings' &&
              (standings.length === 0 ? (
                <EmptyState title={t('session.standings.empty')} />
              ) : (
                <StandingsTable
                  rows={standings.map((row, index) => ({
                    key: row.name,
                    rank: ordinal(index + 1),
                    name: row.name,
                    wins: row.wins,
                    losses: row.losses,
                    diff: row.diff,
                    pointsFor: row.pointsFor,
                  }))}
                  labels={{
                    name: t('session.column.player'),
                    winsLosses: `${t('session.column.wins')}-${t('session.column.losses')}`,
                    diff: t('session.column.diff'),
                    points: t('session.column.points'),
                  }}
                />
              ))}
          </div>
        </>
      )}
    </main>
  )
}