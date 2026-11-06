import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { ApiError } from '../auth/api'
import { t } from '../i18n'
import type { MessageKey } from '../i18n/en'
import { formatCompactDate } from '../utils/day'
import { getSharedSession } from '../share/api'
import type { SharedSession } from '../share/api'
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

type Standing = { name: string; games: number; wins: number; losses: number }

/** Only a played game with both scores is a result; a cancelled one is not. */
function standingsFrom(games: SharedSession['games']): Standing[] {
  const rows = new Map<string, Standing>()
  const row = (name: string): Standing => {
    const existing = rows.get(name)
    if (existing !== undefined) return existing
    const created = { name, games: 0, wins: 0, losses: 0 }
    rows.set(name, created)
    return created
  }
  for (const game of games) {
    if (game.status !== 'played' || game.scoreA === null || game.scoreB === null) continue
    if (game.scoreA === game.scoreB) continue
    const winners = game.scoreA > game.scoreB ? game.sideA : game.sideB
    const losers = game.scoreA > game.scoreB ? game.sideB : game.sideA
    for (const name of winners) {
      const entry = row(name)
      entry.games += 1
      entry.wins += 1
    }
    for (const name of losers) {
      const entry = row(name)
      entry.games += 1
      entry.losses += 1
    }
  }
  return [...rows.values()].sort(
    (a, b) => b.wins - a.wins || b.games - a.games || a.name.localeCompare(b.name),
  )
}

/** Spectators poll, but gently: the share limiter allows 120 reads/minute per code. */
const REFRESH_MS = 10_000
/** Backoff cap after a failure or a `429`. */
const MAX_REFRESH_MS = 60_000

/**
 * The spectator screen. It renders outside the auth gate, so it must not assume
 * a user, a community or a board: everything it shows comes from the code.
 */
export default function SharedSessionPage() {
  const { code = '' } = useParams<{ code: string }>()
  const [settled, setSettled] = useState<Settled | null>(null)

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

  const current = settled !== null && settled.code === code ? settled : null
  const loading = code !== '' && current === null
  const session = current?.value ?? null
  const standings = session === null ? [] : standingsFrom(session.games)

  return (
    <section className="mx-auto max-w-3xl p-4">
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

          <h2 className="mt-6 text-sm font-semibold text-fg">{t('session.games')}</h2>
          {session.games.length === 0 ? (
            <p className="mt-2 text-sm text-fg-dim">{t('session.games.empty')}</p>
          ) : (
            <div className="mt-2 overflow-x-auto rounded-2xl border border-border-subtle bg-surface">
              <table className="w-full border-collapse text-sm">
                <caption className="sr-only">{t('session.games')}</caption>
                <thead>
                  <tr className="border-b border-border text-left text-xs text-fg-dim">
                    <th scope="col" className="px-3 py-2 font-semibold">
                      {t('session.column.court')}
                    </th>
                    <th scope="col" className="px-3 py-2 font-semibold">
                      {t('session.column.sideA')}
                    </th>
                    <th scope="col" className="px-3 py-2 font-semibold">
                      {t('session.column.sideB')}
                    </th>
                    <th scope="col" className="whitespace-nowrap px-3 py-2 text-right font-semibold">
                      {t('session.column.score')}
                    </th>
                    <th scope="col" className="whitespace-nowrap px-3 py-2 text-right font-semibold">
                      {t('session.column.status')}
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {session.games.map((game) => (
                    <tr
                      key={game.id}
                      className="border-b border-border-subtle last:border-b-0"
                    >
                      <td className="px-3 py-2 font-mono text-fg-dim">
                        {game.round + 1}.{game.court + 1}
                      </td>
                      <td className="px-3 py-2">
                        {game.sideA.length === 0
                          ? t('session.side.empty')
                          : game.sideA.join(' & ')}
                      </td>
                      <td className="px-3 py-2">
                        {game.sideB.length === 0
                          ? t('session.side.empty')
                          : game.sideB.join(' & ')}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2 text-right font-mono tabular-nums text-fg">
                        {game.scoreA === null || game.scoreB === null
                          ? '–'
                          : `${game.scoreA}–${game.scoreB}`}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2 text-right text-xs text-fg-dim">
                        {t(
                          game.status === 'played'
                            ? 'shared.gameStatus.played'
                            : game.status === 'cancelled'
                              ? 'shared.gameStatus.cancelled'
                              : 'shared.gameStatus.scheduled',
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          {standings.length > 0 && (
            <>
              <h2 className="mt-6 text-sm font-semibold text-fg">{t('session.standings')}</h2>
              <div className="mt-2 overflow-x-auto rounded-2xl border border-border-subtle bg-surface">
                <table className="w-full border-collapse text-sm">
                  <caption className="sr-only">{t('session.standings')}</caption>
                  <thead>
                    <tr className="border-b border-border text-left text-xs text-fg-dim">
                      <th scope="col" className="px-3 py-2 font-semibold">
                        {t('rankings.column.player')}
                      </th>
                      <th scope="col" className="px-3 py-2 text-right font-semibold">
                        {t('rankings.column.games')}
                      </th>
                      <th scope="col" className="px-3 py-2 text-right font-semibold">
                        {t('rankings.column.wins')}
                      </th>
                      <th scope="col" className="px-3 py-2 text-right font-semibold">
                        {t('rankings.column.losses')}
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {standings.map((row) => (
                      <tr
                        key={row.name}
                        className="border-b border-border-subtle last:border-b-0"
                      >
                        <td className="px-3 py-2 text-fg">{row.name}</td>
                        <td className="px-3 py-2 text-right font-mono text-fg-dim">
                          {row.games}
                        </td>
                        <td className="px-3 py-2 text-right font-mono text-fg">
                          {row.wins}
                        </td>
                        <td className="px-3 py-2 text-right font-mono text-fg-dim">
                          {row.losses}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          )}
        </>
      )}
    </section>
  )
}
