// src/pages/SessionListPage.tsx: logbook of past and active match sessions.
import { useState, useMemo } from 'react'
import { useNavigate } from 'react-router-dom'
import { useListSessions } from '../queries'
import { t } from '../i18n'

const MONTH_NAMES = ['', 'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC']

export default function SessionListPage() {
  const navigate = useNavigate()
  const [query, setQuery] = useState('')
  const [dateFilter, setDateFilter] = useState('')

  const hasFilter = Boolean(query.trim() || dateFilter)
  // The API lists all sessions when no filter is given; the filter bar only
  // narrows the view client-side, so the logbook is browsable without typing.
  const { data: sessions = [], isLoading, isError } = useListSessions({
    q: query.trim() || undefined,
    date: dateFilter || undefined,
  })

  const filtered = useMemo(() => {
    return sessions.filter((s) => {
      if (dateFilter && s.date !== dateFilter) return false
      if (query && !(s.title || '').toLowerCase().includes(query.toLowerCase())) return false
      return true
    })
  }, [sessions, dateFilter, query])

  return (
    <div className="flex flex-col gap-3">
      {/* Header Title */}
      <div className="flex items-baseline justify-between gap-2">
        <h2 className="text-lg font-bold text-fg">{t('sessions.title')}</h2>
        <span className="text-xs font-mono text-fg-dim font-medium">
          {filtered.length} {t('common.total')}
        </span>
      </div>

      {/* Search & Date Filter Bar */}
      <div className="flex flex-col sm:flex-row gap-2">
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder={t('sessions.searchPlaceholder')}
          className="flex-1 bg-elevated border border-border rounded-lg px-3 py-2 text-sm text-fg placeholder:text-fg-dim/60 focus:border-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-indigo-500/50"
        />
        <div className="flex items-center gap-1.5 shrink-0">
          <input
            type="date"
            value={dateFilter}
            onChange={(e) => setDateFilter(e.target.value)}
            className="bg-elevated border border-border rounded-lg px-2.5 py-2 text-xs font-mono text-fg scheme-dark focus:border-accent focus:outline-none"
          />
          {dateFilter && (
            <button
              onClick={() => setDateFilter('')}
              className="text-xs text-fg-dim hover:text-fg border border-border rounded-lg px-2.5 py-2 transition-colors active:scale-95"
            >
              {t('sessions.clear')}
            </button>
          )}
        </div>
      </div>

      {isError && <p className="text-error text-sm">{t('sessions.loadFailed')}</p>}

      {!isError && isLoading && (
        <div className="bg-surface border border-border-subtle rounded-xl overflow-hidden divide-y divide-border-subtle animate-pulse">
          {[0, 1, 2, 3].map((i) => (
            <div key={i} className="flex items-center gap-3.5 px-3.5 py-3">
              <div className="w-11 h-11 bg-slate-700/60 rounded-lg shrink-0" />
              <div className="flex-1 space-y-2">
                <div className="h-4 w-3/4 bg-slate-700/60 rounded" />
                <div className="h-3 w-1/4 bg-slate-700/60 rounded" />
              </div>
              <div className="w-12 h-6 bg-slate-700/60 rounded shrink-0" />
            </div>
          ))}
        </div>
      )}

      {!isError && !isLoading && filtered.length === 0 && (
        <div className="bg-surface border border-border-subtle rounded-xl p-8 text-center">
          <p className="text-fg-dim text-xs font-sans">
            {hasFilter ? t('sessions.noSessionsFound') : t('sessions.noSessionsYet')}
          </p>
        </div>
      )}

      {!isError && !isLoading && filtered.length > 0 && (
        <div className="bg-surface border border-border-subtle rounded-xl divide-y divide-border-subtle overflow-hidden shadow-sm">
          {filtered.map((s) => {
            const dateParts = s.date ? s.date.split('-') : []
            const year = dateParts[0]
            const monthNum = parseInt(dateParts[1] || '0', 10)
            const day = dateParts[2] || '—'
            const month = MONTH_NAMES[monthNum] || ''

            return (
              <button
                key={s.id}
                onClick={() => navigate(`/s/${s.id}`)}
                className="w-full flex items-center gap-3.5 px-3.5 py-3 hover:bg-elevated text-left transition-colors active:bg-elevated/70"
              >
                {/* Date Badge */}
                <div className="w-11 h-11 rounded-lg bg-elevated border border-border flex flex-col items-center justify-center shrink-0">
                  <span className="text-sm font-bold font-mono text-fg leading-none">{day}</span>
                  <span className="text-[9px] font-mono font-semibold text-accent uppercase leading-none mt-1">
                    {month}
                  </span>
                </div>

                {/* Title & Status */}
                <div className="flex-1 min-w-0 flex flex-col justify-center gap-1">
                  <span className="text-sm font-semibold text-fg truncate">
                    {s.title || 'Untitled Session'}
                  </span>
                  <div className="flex items-center gap-2">
                    <span
                      className={`text-[10px] font-mono font-medium px-1.5 py-0.5 rounded border leading-none ${
                        s.locked
                          ? 'text-accent bg-accent/10 border-accent/25'
                          : 'text-emerald-400 bg-emerald-500/10 border-emerald-500/25'
                      }`}
                    >
                      {s.locked ? t('sessions.locked') : t('sessions.active')}
                    </span>
                    <span className="text-[10px] font-mono text-fg-dim">
                      {year}
                    </span>
                  </div>
                </div>

                {/* Counts & Arrow */}
                <div className="shrink-0 flex items-center gap-2">
                  <div className="text-right font-mono flex flex-col items-end">
                    <span className="text-xs font-semibold text-fg">
                      {s.playerCount} <span className="text-[10px] font-sans text-fg-dim font-normal">{t('sessions.players')}</span>
                    </span>
                    <span className="text-[10px] text-fg-dim">
                      {s.totalGames} <span className="text-[9px] font-sans">{t('sessions.games')}</span>
                    </span>
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
                </div>
              </button>
            )
          })}
        </div>
      )}
    </div>
  )
}
