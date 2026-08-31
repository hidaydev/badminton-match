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
          <section className="flex flex-col gap-2">
            <p className="text-[10px] font-sans text-amber-500/80 uppercase tracking-wider">{t('admin.sectionRating')}</p>
            <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
              {slice.length === 0 && <p className="text-fg-dim text-xs font-sans text-center py-4">{t('admin.noSources')}</p>}
              {slice.map((src) => (
                <div key={src.source_id} className="flex flex-wrap items-center gap-2 px-3 py-2">
                  <span className="flex-1 min-w-0 text-fg truncate font-sans text-xs">{src.source_name}</span>
                  <span className="text-[10px] font-sans text-fg-dim">{src.event_count} ev</span>
                  {src.source_kind.startsWith('tournament') && (
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
              ))}
            </div>
            <Pager page={page} total={(sources ?? []).length} onPage={setPage} />
            <div className="flex flex-col gap-1">
              <button
                onClick={() => runRebuild()}
                disabled={rebuilding}
                className="py-2 rounded-lg border border-border-subtle text-sm text-fg-dim hover:text-fg disabled:opacity-40"
              >
                {rebuilding ? t('admin.rebuilding') : t('admin.rebuild')}
              </button>
              {rebuildMsg && (
                <p className={`text-[10px] font-sans ${rebuildMsg.kind === 'ok' ? 'text-emerald-400' : 'text-red-400'}`}>
                  {rebuildMsg.text}
                </p>
              )}
              <p className="text-[10px] text-fg-dim">{t('admin.rebuildHelp')}</p>
            </div>
          </section>
        </>
      )}
    </AdminPageShell>
  )
}
