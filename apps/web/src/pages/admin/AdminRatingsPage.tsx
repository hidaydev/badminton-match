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
          <section className="flex flex-col gap-3">
            <div className="flex items-center justify-between px-0.5">
              <p className="text-xs font-semibold text-fg-dim uppercase tracking-wider">{t('admin.sectionRating')}</p>
              <span className="text-xs font-mono text-fg-dim">{(sources ?? []).length} sources</span>
            </div>

            <div className="bg-surface border border-border-subtle rounded-xl divide-y divide-border-subtle overflow-hidden shadow-xs">
              {slice.length === 0 && <p className="text-fg-dim text-xs font-sans text-center py-6">{t('admin.noSources')}</p>}
              {slice.map((src) => {
                const isT = src.source_kind.startsWith('tournament')
                return (
                  <div key={src.source_id} className="flex items-center justify-between gap-3 px-3.5 py-2.5 hover:bg-elevated/30 transition-colors">
                    <div className="flex flex-col min-w-0">
                      <div className="flex items-center gap-2">
                        <span className="text-sm font-medium text-fg truncate">{src.source_name}</span>
                        {src.finalized && (
                          <span className="text-[10px] font-medium bg-success/15 border border-success/30 text-success px-1.5 py-0.2 rounded-full">
                            Finalized
                          </span>
                        )}
                      </div>
                      <span className="text-[11px] text-fg-dim font-mono mt-0.5">
                        {isT ? 'Tournament' : 'Session'} · {src.event_count} events
                      </span>
                    </div>

                    <div className="flex items-center gap-1.5 shrink-0">
                      {isT && (
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
                        () => adminRequest('POST', isT ? '/ratings/ingest-tournament' : '/ratings/ingest-session',
                          isT ? { tournamentId: src.source_id } : { sessionId: src.source_id }),
                        'Ingested',
                        refreshRatingData,
                      )}>
                        Ingest
                      </ActionButton>
                      <ActionButton tone="red" onClick={() => run(
                        () => adminRequest('POST', isT ? '/ratings/revert-tournament' : '/ratings/revert-session',
                          isT ? { tournamentId: src.source_id } : { sessionId: src.source_id }),
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

            <div className="flex flex-col gap-2 pt-2">
              <button
                onClick={() => runRebuild()}
                disabled={rebuilding}
                className="w-full py-2.5 rounded-xl border border-border-subtle bg-surface hover:bg-elevated text-sm font-semibold text-fg hover:text-accent disabled:opacity-40 transition-colors shadow-xs cursor-pointer flex items-center justify-center gap-2"
              >
                {rebuilding ? (
                  <svg className="animate-spin w-4 h-4 text-accent shrink-0" viewBox="0 0 24 24" fill="none">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
                  </svg>
                ) : (
                  <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="text-accent shrink-0">
                    <path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/>
                    <path d="M21 3v5h-5"/>
                    <path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/>
                    <path d="M8 16H3v5"/>
                  </svg>
                )}
                <span>{rebuilding ? t('admin.rebuilding') : t('admin.rebuild')}</span>
              </button>
              {rebuildMsg && (
                <p className={`text-xs px-3 py-2 rounded-lg font-medium border ${rebuildMsg.kind === 'ok' ? 'bg-success/10 border-success/30 text-success' : 'bg-error/10 border-error/30 text-error'}`}>
                  {rebuildMsg.text}
                </p>
              )}
              <p className="text-xs text-fg-dim px-1">{t('admin.rebuildHelp')}</p>
            </div>
          </section>
        </>
      )}
    </AdminPageShell>
  )
}
