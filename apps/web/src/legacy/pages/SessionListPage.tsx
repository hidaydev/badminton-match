// src/pages/SessionListPage.tsx: logbook of past and active match sessions.
import { useEffect, useState } from 'react'
import { useNavigate } from '../router'
import { useListSessions } from '../queries'
import { getSession, publishSession, currentCommunitySlug } from '../queries/endpoints'
import { getSaveErrorMessage } from '../queries/errors'
import { PENDING_OVERWRITE_WINDOW_MS, recordPendingPublish, useStore } from '../store'
import { useAdmin } from '../context/AdminContext'
import { t } from '../../i18n'

const MONTH_NAMES = ['', 'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC']

export default function SessionListPage() {
  const navigate = useNavigate()
  const { isAdmin } = useAdmin()
  const [query, setQuery] = useState('')
  const [dateFilter, setDateFilter] = useState('')
  const pendingPublish = useStore((s) => s.pendingPublish)
  const setPendingPublish = useStore((s) => s.setPendingPublish)
  const [busyPending, setBusyPending] = useState(false)
  // Both flags are keyed by the record's timestamp: a new record cannot
  // inherit a confirmation panel or an expiry from the previous one.
  const [confirmingAt, setConfirmingAt] = useState<number | null>(null)
  const [expiredAt, setExpiredAt] = useState<number | null>(null)
  const failedAt = pendingPublish?.failedAt ?? null
  const confirmingOverwrite = failedAt !== null && confirmingAt === failedAt
  const overwriteExpired = failedAt !== null && expiredAt === failedAt

  // Hide the overwrite action as soon as the record crosses the window; the
  // handler enforces the same limit in case a click races the timer.
  useEffect(() => {
    if (failedAt === null) return
    const remaining = failedAt + PENDING_OVERWRITE_WINDOW_MS - Date.now()
    const timer = setTimeout(() => setExpiredAt(failedAt), Math.max(0, remaining))
    return () => clearTimeout(timer)
  }, [failedAt])

  const hasFilter = Boolean(query.trim() || dateFilter)
  // Server-side search and paging: the query covers the whole logbook, and
  // "load more" asks for the next page instead of the list stopping at 100.
  const {
    data: filtered = [],
    total,
    isLoading,
    isError,
    hasMore,
    loadMore,
    isLoadingMore,
    refetch,
  } = useListSessions({
    q: query.trim() || undefined,
    date: dateFilter || undefined,
  })

  /** The record may only be touched while it still belongs to this session. */
  function activePendingSessionId(): string | null {
    if (pendingPublish === null) return null
    if (currentCommunitySlug() === '') return null
    if (useStore.getState().cloudSessionId !== pendingPublish.cloudSessionId) return null
    return pendingPublish.cloudSessionId
  }

  /** The safe default: show the server's current state and drop the copy. */
  function reloadPendingSession() {
    if (pendingPublish === null) return
    const cloudSessionId = pendingPublish.cloudSessionId
    if (activePendingSessionId() !== null && !busyPending) {
      setPendingPublish(null)
    }
    navigate(`/s/${cloudSessionId}`)
  }

  /**
   * Forcing a stale copy over the server replaces the whole schedule, so this
   * only runs from the explicit confirmation and only inside the age window.
   */
  async function overwritePendingPublish() {
    if (pendingPublish === null || busyPending) return
    const cloudSessionId = activePendingSessionId()
    if (cloudSessionId === null) return
    if (Date.now() - pendingPublish.failedAt > PENDING_OVERWRITE_WINDOW_MS) {
      setExpiredAt(pendingPublish.failedAt)
      setConfirmingAt(null)
      return
    }
    setBusyPending(true)
    setConfirmingAt(null)
    try {
      // The stored basis is older than the server. This is an explicit,
      // confirmed overwrite, so read the current version once and publish the
      // copy on top of it.
      const fresh = await getSession(cloudSessionId)
      const snapshot = fresh?.version != null
        ? { ...pendingPublish.snapshot, version: fresh.version }
        : pendingPublish.snapshot
      const updated = await publishSession(cloudSessionId, snapshot)
      if (useStore.getState().cloudSessionId === cloudSessionId) {
        useStore.getState().setCloudVersion(updated?.version ?? null)
        useStore.getState().setPendingPublish(null)
        await refetch()
      }
    } catch (error) {
      // Refuse to write after expiry: the 401 handler may already have cleared
      // the store for the next account on this device.
      recordPendingPublish({ ...pendingPublish, message: getSaveErrorMessage(error) })
    } finally {
      setBusyPending(false)
    }
  }

  return (
    <div className="flex flex-col gap-3">
      {/* Header Title */}
      <div className="flex items-baseline justify-between gap-2">
        <h2 className="text-lg font-bold text-fg">{t('sessions.title')}</h2>
        <span className="text-xs font-mono text-fg-dim font-medium">
          {hasFilter ? `${filtered.length} / ${total}` : total} {t('common.total')}
        </span>
      </div>

      {/* A write that did not reach the server is never dropped. Reloading
          the session is the default: it shows the current server state. The
          copy may only be forced over a collaborator after an explicit
          confirmation, and only while the record is fresh. */}
      {pendingPublish && (
        <div role="alert" className="flex flex-col gap-3 rounded-xl border border-error/60 bg-error/10 p-3 sm:flex-row sm:items-start">
          <div className="flex-1 min-w-0">
            <p className="text-sm font-semibold text-fg">{t('sessions.unsaved.title')}</p>
            <p className="text-xs text-fg-dim">
              {pendingPublish.message ?? t('sessions.unsaved.body')}
            </p>
            {overwriteExpired && (
              <p className="mt-1 text-xs text-fg-dim">{t('sessions.unsaved.tooOld')}</p>
            )}
          </div>

          {confirmingOverwrite ? (
            <div className="flex shrink-0 flex-col gap-2 sm:items-end">
              <p className="text-xs font-semibold text-fg">{t('sessions.unsaved.confirm')}</p>
              <p className="text-xs text-fg-dim">{t('sessions.unsaved.confirmBody')}</p>
              <div className="flex items-center gap-2">
                <button
                  type="button"
                  onClick={() => setConfirmingAt(null)}
                  disabled={busyPending}
                  className="min-h-11 rounded-lg border border-border px-3 text-xs font-mono text-fg-dim transition-colors hover:text-fg disabled:opacity-50"
                >
                  {t('sessions.unsaved.cancel')}
                </button>
                <button
                  type="button"
                  onClick={() => void overwritePendingPublish()}
                  disabled={busyPending}
                  className="min-h-11 rounded-lg border border-error bg-error/20 px-3 text-xs font-bold text-error transition-colors hover:bg-error/30 disabled:opacity-50"
                >
                  {busyPending ? t('sessions.unsaved.overwriting') : t('sessions.unsaved.confirmYes')}
                </button>
              </div>
            </div>
          ) : (
            <div className="flex shrink-0 flex-wrap items-center gap-2">
              <button
                type="button"
                onClick={reloadPendingSession}
                disabled={busyPending}
                className="min-h-11 rounded-lg border border-accent/60 px-3 text-xs font-semibold text-accent transition-colors hover:bg-accent/10 disabled:opacity-50"
              >
                {t('sessions.unsaved.reload')}
              </button>
              {!overwriteExpired && (
                <button
                  type="button"
                  onClick={() => setConfirmingAt(pendingPublish.failedAt)}
                  disabled={busyPending}
                  className="min-h-11 rounded-lg border border-error/60 px-3 text-xs font-semibold text-error transition-colors hover:bg-error/10 disabled:opacity-50"
                >
                  {t('sessions.unsaved.overwrite')}
                </button>
              )}
              <button
                type="button"
                onClick={() => setPendingPublish(null)}
                disabled={busyPending}
                className="min-h-11 rounded-lg border border-border px-3 text-xs font-mono text-fg-dim transition-colors hover:text-fg disabled:opacity-50"
              >
                {t('sessions.unsaved.dismiss')}
              </button>
            </div>
          )}
        </div>
      )}

      {/* Search & Date Filter Bar */}
      <div className="flex flex-col sm:flex-row gap-2">
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder={t('sessions.searchPlaceholder')}
          aria-label={t('sessions.searchPlaceholder')}
          className="flex-1 bg-elevated border border-border rounded-lg px-3 py-2 text-sm text-fg placeholder:text-fg-dim focus:border-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-accent"
        />
        <div className="flex items-center gap-1.5 shrink-0">
          <input
            type="date"
            value={dateFilter}
            onChange={(e) => setDateFilter(e.target.value)}
            aria-label={t('sessions.filterDate')}
            className="bg-elevated border border-border rounded-lg px-2.5 py-2 text-xs font-mono text-fg focus:border-accent focus:outline-none"
          />
          {dateFilter && (
            <button
              onClick={() => setDateFilter('')}
              className="text-xs text-fg-dim hover:text-fg border border-border rounded-lg px-2.5 py-2 transition-colors active:scale-95 hit44"
            >
              {t('sessions.clear')}
            </button>
          )}
        </div>
      </div>

      {isError && (
        <div className="flex items-center gap-3">
          <p role="alert" className="text-error text-sm">{t('sessions.loadFailed')}</p>
          <button
            type="button"
            onClick={() => void refetch()}
            className="text-xs font-medium text-accent hover:underline hit44"
          >
            Retry
          </button>
        </div>
      )}

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
          {(hasFilter || isAdmin) && (
            <p className="mt-1 text-xs font-sans text-fg-dim">
              {hasFilter ? t('sessions.emptyHintFilter') : t('sessions.emptyHint')}
            </p>
          )}
          {hasFilter ? (
            <button
              onClick={() => {
                setQuery('')
                setDateFilter('')
              }}
              className="mt-3 min-h-11 rounded-xl border border-border px-3 text-xs font-mono text-fg-dim hover:text-fg transition-colors"
            >
              {t('sessions.clearFilters')}
            </button>
          ) : (
            isAdmin && (
              <button
                onClick={() => navigate('/session/new')}
                className="mt-3 min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground transition-colors active:scale-[0.98]"
              >
                {t('home.newSession')}
              </button>
            )
          )}
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
                className="w-full flex items-center gap-3.5 px-3.5 py-3 hover:bg-elevated text-left transition-colors active:bg-elevated/70 hit44"
              >
                {/* Date Badge */}
                <div className="w-11 h-11 rounded-lg bg-elevated border border-border flex flex-col items-center justify-center shrink-0">
                  <span className="text-sm font-bold font-mono text-fg leading-none">{day}</span>
                  <span className="text-[11px] font-mono font-semibold text-accent uppercase leading-none mt-1">
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
                      {s.totalGames} <span className="text-[11px] font-sans">{t('sessions.games')}</span>
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

      {!isError && !isLoading && hasMore && (
        <button
          onClick={() => loadMore()}
          disabled={isLoadingMore}
          className="self-center text-xs font-mono text-fg-dim hover:text-fg border border-border rounded-lg px-3 py-2 transition-colors active:scale-95 disabled:opacity-50 hit44"
        >
          {isLoadingMore ? '…' : t('sessions.loadMore')}
        </button>
      )}
    </div>
  )
}
