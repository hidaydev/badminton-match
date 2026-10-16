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
          <section className="flex flex-col gap-3">
            <div className="flex items-center justify-between px-0.5">
              <p className="text-xs font-semibold text-fg-dim uppercase tracking-wider">{t('admin.sectionSession')}</p>
              <span className="text-xs font-mono text-fg-dim">{(sessions ?? []).length} sessions</span>
            </div>

            <div className="bg-surface border border-border-subtle rounded-xl divide-y divide-border-subtle overflow-hidden shadow-xs">
              {slice.length === 0 && <p className="text-fg-dim text-xs font-sans text-center py-6">{t('admin.noSessions')}</p>}
              {slice.map((s) => (
                <div key={s.id} className="flex items-center justify-between gap-3 px-3.5 py-2.5 hover:bg-elevated/30 transition-colors">
                  <div className="flex flex-col min-w-0">
                    <span className="text-sm font-medium text-fg truncate">{s.title || 'Untitled'}</span>
                    <div className="flex items-center gap-2 text-[11px] text-fg-dim font-mono mt-0.5">
                      <span>{s.date}</span>
                      <span>·</span>
                      <span className={s.locked ? 'text-accent font-medium font-sans' : 'text-fg-dim font-sans'}>
                        {s.locked ? t('admin.locked') : t('admin.draft')}
                      </span>
                    </div>
                  </div>

                  <div className="flex items-center gap-1.5 shrink-0">
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
