import { useMemo, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { t } from '../i18n'
import { useSessions } from '../sessions/hooks'

const MONTH_NAMES = ['', 'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC']

/** The logbook of past and active sessions, in the shape the club knows. */
export default function SessionsPage() {
  const { slug = '' } = useParams<{ slug: string }>()
  const { items, loading, error } = useSessions(slug === '' ? null : slug)
  const [query, setQuery] = useState('')
  const [dateFilter, setDateFilter] = useState('')

  const hasFilter = query.trim() !== '' || dateFilter !== ''
  const filtered = useMemo(() => {
    return (items ?? []).filter((session) => {
      if (dateFilter !== '' && session.date !== dateFilter) return false
      if (query.trim() !== '' && !session.title.toLowerCase().includes(query.trim().toLowerCase())) return false
      return true
    })
  }, [items, dateFilter, query])

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-baseline justify-between gap-2">
        <h2 className="text-lg font-bold text-fg">{t('sessions.title')}</h2>
        <span className="text-xs font-mono text-fg-dim font-medium">
          {filtered.length} {t('sessions.total')}
        </span>
      </div>

      <div className="flex flex-col sm:flex-row gap-2">
        <input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder={t('sessions.searchPlaceholder')}
          aria-label={t('sessions.searchPlaceholder')}
          className="flex-1 bg-elevated border border-border rounded-lg px-3 py-2 text-sm text-fg placeholder:text-fg-dim/60 focus:border-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-accent"
        />
        <div className="flex items-center gap-1.5 shrink-0">
          <input
            type="date"
            value={dateFilter}
            onChange={(event) => setDateFilter(event.target.value)}
            aria-label={t('wizard.setup.date')}
            className="bg-elevated border border-border rounded-lg px-2.5 py-2 text-xs font-mono text-fg focus:border-accent focus:outline-none"
          />
          {dateFilter !== '' && (
            <button
              type="button"
              onClick={() => setDateFilter('')}
              className="text-xs text-fg-dim hover:text-fg border border-border rounded-lg px-2.5 py-2 transition-colors active:scale-95"
            >
              {t('sessions.clear')}
            </button>
          )}
        </div>
      </div>

      {error === 'notFound' && (
        <p role="alert" className="text-sm text-error">
          {t('sessions.error.notFound')}
        </p>
      )}
      {error === 'failed' && (
        <p role="alert" className="text-sm text-error">
          {t('sessions.error.load')}
        </p>
      )}

      {loading && (
        <div className="bg-surface border border-border-subtle rounded-xl overflow-hidden divide-y divide-border-subtle animate-pulse">
          {[0, 1, 2, 3].map((index) => (
            <div key={index} className="flex items-center gap-3.5 px-3.5 py-3">
              <div className="w-11 h-11 bg-slate-700/60 rounded-lg shrink-0" />
              <div className="flex-1 space-y-2">
                <div className="h-4 w-3/4 bg-slate-700/60 rounded" />
                <div className="h-3 w-1/4 bg-slate-700/60 rounded" />
              </div>
            </div>
          ))}
        </div>
      )}

      {!loading && error === null && filtered.length === 0 && (
        <div className="bg-surface border border-border-subtle rounded-xl p-8 text-center">
          <p className="text-fg-dim text-xs font-sans">
            {hasFilter ? t('sessions.noFound') : t('sessions.empty')}
          </p>
        </div>
      )}

      {!loading && error === null && filtered.length > 0 && (
        <div className="bg-surface border border-border-subtle rounded-xl divide-y divide-border-subtle overflow-hidden shadow-sm">
          {filtered.map((session) => {
            const parts = session.date.split('-')
            const year = parts[0] ?? ''
            const month = MONTH_NAMES[parseInt(parts[1] ?? '0', 10)] ?? ''
            const day = parts[2] ?? '—'
            const locked = session.status === 'locked'

            return (
              <Link
                key={session.id}
                to={`/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(session.id)}`}
                className="w-full flex items-center gap-3.5 px-3.5 py-3 hover:bg-elevated text-left transition-colors active:bg-elevated/70"
              >
                <div className="w-11 h-11 rounded-lg bg-elevated border border-border flex flex-col items-center justify-center shrink-0">
                  <span className="text-sm font-bold font-mono text-fg leading-none">{day}</span>
                  <span className="text-[9px] font-mono font-semibold text-accent uppercase leading-none mt-1">{month}</span>
                </div>

                <div className="flex-1 min-w-0 flex flex-col justify-center gap-1">
                  <span className="text-sm font-semibold text-fg truncate">
                    {session.title || t('sessions.untitled')}
                  </span>
                  <div className="flex items-center gap-2">
                    <span
                      className={`text-[10px] font-mono font-medium px-1.5 py-0.5 rounded border leading-none ${
                        locked
                          ? 'text-accent bg-accent/10 border-accent/25'
                          : 'text-emerald-400 bg-emerald-500/10 border-emerald-500/25'
                      }`}
                    >
                      {locked ? t('sessions.locked') : t('sessions.active')}
                    </span>
                    <span className="text-[10px] font-mono text-fg-dim">{year}</span>
                  </div>
                </div>

                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  width="16"
                  height="16"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  className="text-fg-dim/40 shrink-0 ml-1"
                >
                  <path d="M9 18l6-6-6-6" />
                </svg>
              </Link>
            )
          })}
        </div>
      )}
    </div>
  )
}
