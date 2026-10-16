// src/pages/admin/AdminRatingsPage.tsx — Admin: ingest, revert, rebuild ratings.
import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useRatingSources } from '../../queries/ratings'
import { adminRequest } from '../../queries/admin'
import { t } from '../../i18n'
import AdminPageShell from '../../components/admin/AdminPageShell'
import ActionButton from '../../components/admin/ActionButton'
import Pager from '../../components/admin/Pager'

const PAGE = 10

export default function AdminRatingsPage() {
  const queryClient = useQueryClient()
  const [page, setPage] = useState(0)
  const { data: sources, refetch } = useRatingSources()
  const [rebuildMsg, setRebuildMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null)
  const [rebuilding, setRebuilding] = useState(false)

  const refreshRatingData = () => {
    void refetch()
    void queryClient.invalidateQueries({ queryKey: ['ratings'] })
  }

  const slice = (sources ?? []).slice(page * PAGE, page * PAGE + PAGE)

  const runRebuild = async () => {
    if (rebuilding) return
    setRebuilding(true)
    setRebuildMsg(null)
    try {
      await adminRequest('POST', '/ratings/rebuild-all')
      setRebuildMsg({ kind: 'ok', text: t('admin.rebuildDone') })
      refreshRatingData()
    } catch (e) {
      setRebuildMsg({ kind: 'err', text: e instanceof Error ? e.message : 'Rebuild failed' })
    } finally {
      setRebuilding(false)
      setTimeout(() => setRebuildMsg(null), 5000)
    }
  }

  return (
    <AdminPageShell>
      {({ run }) => (
        <>
          {/* Hero: Rebuild All Ratings Card */}
          <div className="bg-surface border border-border-subtle rounded-xl p-4 flex flex-col gap-3 shadow-xs">
            <div className="flex items-start gap-3">
              <div className="w-10 h-10 rounded-xl bg-accent/10 border border-accent/30 flex items-center justify-center text-accent shrink-0 mt-0.5">
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                  <path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.67-5.67"/>
                </svg>
              </div>
              <div className="flex flex-col min-w-0">
                <h3 className="text-sm font-bold text-fg leading-tight">{t('admin.rebuild')}</h3>
                <p className="text-xs text-fg-dim leading-snug mt-1">{t('admin.rebuildHelp')}</p>
              </div>
            </div>

            <button
              onClick={() => runRebuild()}
              disabled={rebuilding}
              className="w-full py-2.5 px-4 rounded-lg bg-accent text-slate-950 font-bold text-xs flex items-center justify-center gap-2 hover:brightness-110 active:scale-[0.98] transition-all disabled:opacity-40 shadow-xs cursor-pointer"
            >
              {rebuilding ? (
                <>
                  <svg className="animate-spin w-3.5 h-3.5 shrink-0" viewBox="0 0 24 24" fill="none">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                  </svg>
                  <span>{t('admin.rebuilding')}</span>
                </>
              ) : (
                <span>{t('admin.rebuild')}</span>
              )}
            </button>

            {rebuildMsg && (
              <p className={`text-xs px-3 py-2 rounded-lg font-medium border ${rebuildMsg.kind === 'ok' ? 'bg-success/15 border-success/30 text-success' : 'bg-error/15 border-error/30 text-error'}`}>
                {rebuildMsg.text}
              </p>
            )}
          </div>

          {/* Sources Section */}
          <section className="flex flex-col gap-2.5">
            <div className="flex items-center justify-between px-1">
              <p className="text-xs font-semibold text-fg-dim uppercase tracking-wider">{t('admin.sectionRating')}</p>
              <span className="text-xs font-mono text-fg-dim">{(sources ?? []).length} sources</span>
            </div>

            <div className="bg-surface border border-border-subtle rounded-xl divide-y divide-border-subtle overflow-hidden shadow-xs">
              {slice.length === 0 && (
                <div className="flex flex-col items-center justify-center py-8 text-center gap-2">
                  <span className="text-2xl">📊</span>
                  <p className="text-fg-dim text-xs">{t('admin.noSources')}</p>
                </div>
              )}
              {slice.map((src) => {
                const isTournament = src.source_kind.startsWith('tournament')
                return (
                  <div key={src.source_id} className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 px-4 py-3 hover:bg-elevated/20 transition-colors">
                    <div className="flex items-start gap-3 min-w-0">
                      <span className="text-lg shrink-0 mt-0.5">{isTournament ? '🏆' : '🏸'}</span>
                      <div className="flex flex-col min-w-0">
                        <div className="flex items-center gap-2 flex-wrap">
                          <span className="text-sm font-semibold text-fg truncate">{src.source_name}</span>
                          <span className={`text-[10px] font-mono uppercase px-1.5 py-0.2 rounded border ${isTournament ? 'bg-accent/10 border-accent/30 text-accent font-semibold' : 'bg-elevated border-border-subtle text-fg-dim'}`}>
                            {isTournament ? 'Tournament' : 'Session'}
                          </span>
                          {src.finalized && (
                            <span className="text-[10px] font-medium bg-success/15 border border-success/30 text-success px-1.5 py-0.2 rounded-full">
                              Finalized
                            </span>
                          )}
                        </div>
                        <div className="flex items-center gap-2 mt-0.5 text-[11px] text-fg-dim">
                          <span className="font-mono">{src.event_count} events</span>
                          {src.ingested_at && (
                            <span>· Ingested {new Date(src.ingested_at).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}</span>
                          )}
                        </div>
                      </div>
                    </div>

                    <div className="flex items-center gap-2 self-end sm:self-auto shrink-0">
                      {isTournament && (
                        <ActionButton
                          tone={src.finalized ? 'green' : 'neutral'}
                          onClick={() => run(
                            () => adminRequest('POST', `/ratings/sources/${src.source_id}/finalize`, { finalized: !src.finalized }),
                            src.finalized ? 'Un-finalized' : 'Finalized',
                            refreshRatingData,
                          )}
                        >
                          {src.finalized ? 'Finalized' : 'Finalize'}
                        </ActionButton>
                      )}
                      <ActionButton onClick={() => run(
                        () => {
                          const isT = src.source_kind.startsWith('tournament')
                          return adminRequest('POST', isT ? '/ratings/ingest-tournament' : '/ratings/ingest-session',
                            isT ? { tournamentId: src.source_id } : { sessionId: src.source_id })
                        },
                        'Ingested',
                        refreshRatingData,
                      )}>
                        Ingest
                      </ActionButton>
                      <ActionButton tone="red" onClick={() => run(
                        () => {
                          const isT = src.source_kind.startsWith('tournament')
                          return adminRequest('POST', isT ? '/ratings/revert-tournament' : '/ratings/revert-session',
                            isT ? { tournamentId: src.source_id } : { sessionId: src.source_id })
                        },
                        'Reverted',
                        refreshRatingData,
                      )}>
                        Revert
                      </ActionButton>
                    </div>
                  </div>
                )
              })}
            </div>
            <Pager page={page} total={(sources ?? []).length} onPage={setPage} />
          </section>
        </>
      )}
    </AdminPageShell>
  )
}
