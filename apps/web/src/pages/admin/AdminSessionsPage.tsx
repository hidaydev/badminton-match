// src/pages/admin/AdminSessionsPage.tsx — Admin: unlock & delete sessions.
import { useState } from 'react'
import { useListSessions } from '../../queries'
import { adminRequest } from '../../queries/admin'
import { t, en } from '../../i18n'
import AdminPageShell from '../../components/admin/AdminPageShell'
import ActionButton from '../../components/admin/ActionButton'
import Pager from '../../components/admin/Pager'

const PAGE = 10

export default function AdminSessionsPage() {
  const [page, setPage] = useState(0)
  const { data: sessions, refetch } = useListSessions()

  const slice = (sessions ?? []).slice(page * PAGE, page * PAGE + PAGE)

  return (
    <AdminPageShell>
      {({ run }) => (
        <>
          <section className="flex flex-col gap-2.5">
            <div className="flex items-center justify-between px-1">
              <p className="text-xs font-semibold text-fg-dim uppercase tracking-wider">{t('admin.sectionSession')}</p>
              <span className="text-xs font-mono text-fg-dim">{(sessions ?? []).length} sessions</span>
            </div>

            <div className="bg-surface border border-border-subtle rounded-xl divide-y divide-border-subtle overflow-hidden shadow-xs">
              {slice.length === 0 && (
                <div className="flex flex-col items-center justify-center py-8 text-center gap-2">
                  <span className="text-2xl">🏸</span>
                  <p className="text-fg-dim text-xs font-sans">{t('admin.noSessions')}</p>
                </div>
              )}
              {slice.map((s) => (
                <div key={s.id} className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 px-4 py-3 hover:bg-elevated/20 transition-colors">
                  <div className="flex items-start gap-3 min-w-0">
                    <span className="text-lg shrink-0 mt-0.5">🏸</span>
                    <div className="flex flex-col min-w-0">
                      <div className="flex items-center gap-2 flex-wrap">
                        <span className="text-sm font-semibold text-fg truncate">{s.title || 'Untitled'}</span>
                        <span className={`text-[10px] font-medium px-2 py-0.5 rounded-full border ${s.locked ? 'bg-amber-400/10 text-amber-300 border-amber-400/30' : 'bg-elevated border-border-subtle text-fg-dim'}`}>
                          {s.locked ? t('admin.locked') : t('admin.draft')}
                        </span>
                      </div>
                      <div className="flex items-center gap-2 mt-0.5 text-[11px] text-fg-dim font-mono">
                        <span>{s.date}</span>
                      </div>
                    </div>
                  </div>

                  <div className="flex items-center gap-2 self-end sm:self-auto shrink-0">
                    {s.locked && (
                      <ActionButton tone="amber" onClick={() => run(
                        () => adminRequest('POST', `/sessions/${s.id}/unlock`),
                        t('admin.unlocked'),
                        () => refetch(),
                      )}>
                        Unlock
                      </ActionButton>
                    )}
                    <ActionButton
                      tone="red"
                      onClick={() => {
                        if (window.confirm(en.admin.sessionDeleteConfirm(s.title || 'Untitled', s.date))) {
                          run(
                            () => adminRequest('POST', `/sessions/${s.id}/delete`),
                            t('admin.sessionDeleted'),
                            () => refetch(),
                          )
                        }
                      }}
                    >
                      Delete
                    </ActionButton>
                  </div>
                </div>
              ))}
            </div>
            <Pager page={page} total={(sessions ?? []).length} onPage={setPage} />
          </section>
        </>
      )}
    </AdminPageShell>
  )
}
