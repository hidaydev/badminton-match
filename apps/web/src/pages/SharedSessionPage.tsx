import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { ApiError } from '../auth/api'
import { t } from '../i18n'
import type { MessageKey } from '../i18n/en'
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

function formatSessionDate(date: string): string {
  const parsed = new Date(`${date}T00:00:00`)
  if (Number.isNaN(parsed.getTime())) return date
  return parsed.toLocaleDateString('en-US', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  })
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
              {formatSessionDate(session.session.date)}
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
                    <th scope="col" className="px-3 py-2 text-right font-semibold">
                      {t('session.column.score')}
                    </th>
                    <th scope="col" className="px-3 py-2 text-right font-semibold">
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
                      <td className="px-3 py-2 text-right font-mono text-fg">
                        {game.scoreA === null || game.scoreB === null
                          ? '–'
                          : `${game.scoreA}–${game.scoreB}`}
                      </td>
                      <td className="px-3 py-2 text-right text-xs text-fg-dim">
                        {game.status}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </section>
  )
}
