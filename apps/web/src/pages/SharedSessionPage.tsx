import { useEffect, useId, useState } from 'react'
import type { KeyboardEvent } from 'react'
import { useParams } from 'react-router-dom'
import { ApiError } from '../auth/api'
import { t } from '../i18n'
import type { MessageKey } from '../i18n/en'
import { formatCompactDate } from '../utils/day'
import { ordinal } from '../legacy/utils/ordinal'
import { getSharedSession } from '../share/api'
import type { SharedGame, SharedSession, SharedStanding } from '../share/api'
import { LoadingState } from '../components/LoadingState'

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

const TABS = ['games', 'standings'] as const
type Tab = (typeof TABS)[number]

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
  const tally = (name: string, pointsFor: number, pointsAgainst: number) => {
    const row = rows.get(name) ?? {
      name,
      wins: 0,
      losses: 0,
      pointsFor: 0,
      pointsAgainst: 0,
      diff: 0,
    }
    if (pointsFor > pointsAgainst) row.wins += 1
    else row.losses += 1
    row.pointsFor += pointsFor
    row.pointsAgainst += pointsAgainst
    rows.set(name, row)
  }
  for (const game of games) {
    if (game.status !== 'played' || game.scoreA === null || game.scoreB === null) continue
    if (game.sideA.length === 0 || game.sideB.length === 0) continue
    for (const name of game.sideA) tally(name, game.scoreA, game.scoreB)
    for (const name of game.sideB) tally(name, game.scoreB, game.scoreA)
  }
  for (const row of rows.values()) row.diff = row.pointsFor - row.pointsAgainst
  return [...rows.values()].sort(
    (a, b) =>
      b.wins - a.wins ||
      b.diff - a.diff ||
      b.pointsFor - a.pointsFor ||
      a.name.localeCompare(b.name),
  )
}

/** Spectators poll, but gently: the share limiter allows 120 reads/minute per code. */
const REFRESH_MS = 10_000
/** Backoff cap after a failure or a `429`. */
const MAX_REFRESH_MS = 60_000

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

  useEffect(() => {
    if (code === '') return
    let active = true
    let timer: ReturnType<typeof setTimeout> | null = null
    let failures = 0
    let inFlight = false

    const stop = () => {
      if (timer !== null) {
        clearTimeout(timer)
        timer = null
      }
    }

    // A hidden tab costs nothing; the next focus refetches anyway.
    const schedule = (delay: number) => {
      stop()
      if (!active || document.hidden) return
      timer = setTimeout(() => { void load() }, delay)
    }

    async function load(): Promise<void> {
      // One read at a time: a focus event during a poll joins that read.
      if (!active || inFlight) return
      inFlight = true
      try {
        const value = await getSharedSession(code)
        if (!active) return
        failures = 0
        setSettled({ code, value, error: null })
        schedule(REFRESH_MS)
      } catch (problem) {
        if (!active) return
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
        schedule(Math.min(MAX_REFRESH_MS, REFRESH_MS * 2 ** failures))
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
    return () => {
      active = false
      stop()
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('focus', refreshNow)
    }
  }, [code])

  function handleTabKey(event: KeyboardEvent<HTMLDivElement>) {
    const index = TABS.indexOf(tab)
    let next: Tab | null = null
    if (event.key === 'ArrowRight') next = TABS[(index + 1) % TABS.length]
    else if (event.key === 'ArrowLeft') next = TABS[(index - 1 + TABS.length) % TABS.length]
    else if (event.key === 'Home') next = TABS[0]
    else if (event.key === 'End') next = TABS[TABS.length - 1]
    if (next === null) return
    event.preventDefault()
    setTab(next)
    const tabs = event.currentTarget.querySelectorAll<HTMLElement>('[role="tab"]')
    tabs[TABS.indexOf(next)]?.focus()
  }

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
    <section className="mx-auto flex w-full max-w-xl flex-col p-4">
      <header className="flex items-baseline justify-between gap-3">
        <p className="text-sm font-semibold text-accent">{t('shared.title')}</p>
        {session !== null && (
          <p className="text-xs text-fg-dim">{session.community.name}</p>
        )}
      </header>

      {loading && <LoadingState label={t('app.loading')} rows={1} />}
      {current?.error === 'notFound' && (
        <p role="alert" className="mt-4 text-sm text-error">
          {t('shared.error.missing')}
        </p>
      )}
      {current?.error === 'failed' && (
        <p role="alert" className="mt-4 text-sm text-error">
          {t('shared.error.load')}
        </p>
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
          </p>

          <div
            className="mt-4 flex flex-wrap items-center gap-2 border-b border-slate-800 pb-3"
            role="tablist"
            aria-label={t('shared.tabs')}
            onKeyDown={handleTabKey}
          >
            <div className="flex gap-1">
              <button
                id={`${panelId}-games`}
                role="tab"
                aria-selected={tab === 'games'}
                aria-controls={panelId}
                tabIndex={tab === 'games' ? 0 : -1}
                onClick={() => setTab('games')}
                className={`text-xs font-semibold px-3 py-1.5 rounded-lg transition-colors ${tab === 'games' ? 'bg-indigo-900/60 border border-indigo-700 text-indigo-300' : 'text-slate-400 hover:text-slate-200'}`}
              >
                {t('session.games')}
              </button>
              <button
                id={`${panelId}-standings`}
                role="tab"
                aria-selected={tab === 'standings'}
                aria-controls={panelId}
                tabIndex={tab === 'standings' ? 0 : -1}
                onClick={() => setTab('standings')}
                className={`text-xs font-semibold px-3 py-1.5 rounded-lg transition-colors ${tab === 'standings' ? 'bg-indigo-900/60 border border-indigo-700 text-indigo-300' : 'text-slate-400 hover:text-slate-200'}`}
              >
                {t('session.standings')}
              </button>
            </div>
            {rounds.length > 0 && (
              <span className="text-xs text-slate-400">
                {t('shared.gamesCount', { games: session.games.length })}
              </span>
            )}
          </div>

          <div
            id={panelId}
            role="tabpanel"
            aria-labelledby={`${panelId}-${tab}`}
            className="mt-3 flex flex-col"
          >
            {tab === 'games' &&
              (session.games.length === 0 ? (
                <p className="mt-2 text-sm text-slate-400">{t('session.games.empty')}</p>
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
                                <span className="shrink-0 whitespace-nowrap text-[11px] font-bold tabular-nums text-emerald-300">
                                  {game.scoreA}–{game.scoreB}
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
                <p className="mt-2 text-sm text-slate-400">{t('session.standings.empty')}</p>
              ) : (
                <div className="flex flex-col gap-1.5">
                  <div className="flex items-center gap-2 pl-2 pr-2 mb-1">
                    <span className="w-8 shrink-0 text-center text-[10px] font-bold text-slate-400">
                      {t('session.column.rank')}
                    </span>
                    <span className="flex-1 text-[10px] font-bold text-slate-400">
                      {t('session.column.player')}
                    </span>
                    <span className="w-11 shrink-0 text-center text-[10px] font-bold text-slate-400">
                      {t('session.column.wins')}-{t('session.column.losses')}
                    </span>
                    <span className="w-9 shrink-0 text-center text-[10px] font-bold text-slate-400">
                      {t('session.column.diff')}
                    </span>
                    <span className="w-9 shrink-0 text-center text-[10px] font-bold text-slate-400">
                      {t('session.column.points')}
                    </span>
                  </div>
                  <ol role="list" className="flex flex-col gap-1.5">
                    {standings.map((row, index) => {
                      const rank = index + 1
                      const podium = rank <= 3
                      const wlColor =
                        row.wins > row.losses
                          ? 'text-emerald-400'
                          : row.losses > row.wins
                            ? 'text-red-400'
                            : 'text-slate-400'
                      const diffColor =
                        row.diff > 0
                          ? 'text-emerald-400'
                          : row.diff < 0
                            ? 'text-red-400'
                            : 'text-slate-400'
                      return (
                        <li
                          key={row.name}
                          className={`flex items-center gap-2 pl-2 pr-2 py-2.5 rounded-xl border ${podium ? 'bg-emerald-950/45 border-emerald-800/35' : 'bg-slate-800/30 border-slate-700/20'}`}
                        >
                          <span
                            className={`w-8 shrink-0 text-center text-[11px] font-bold ${rank === 1 ? 'text-accent' : rank === 2 ? 'text-slate-200' : 'text-slate-400'}`}
                          >
                            {ordinal(rank)}
                          </span>
                          <span
                            className={`flex-1 min-w-0 truncate ${rank === 1 ? 'text-sm font-bold text-emerald-300' : podium ? 'text-sm font-semibold text-emerald-100/80' : 'text-sm font-medium text-slate-400'}`}
                          >
                            {row.name}
                          </span>
                          <span className={`w-11 shrink-0 text-center text-[11px] font-semibold ${wlColor}`}>
                            {row.wins}-{row.losses}
                          </span>
                          <span className={`w-9 shrink-0 text-center text-[11px] font-semibold ${diffColor}`}>
                            {row.diff > 0 ? `+${row.diff}` : String(row.diff)}
                          </span>
                          <span className="w-9 shrink-0 text-center text-[11px] font-semibold text-slate-400">
                            {row.pointsFor}
                          </span>
                        </li>
                      )
                    })}
                  </ol>
                </div>
              ))}
          </div>
        </>
      )}
    </section>
  )
}