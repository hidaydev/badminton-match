// src/pages/admin/AdminSessionsPage.tsx — Admin: unlock & delete sessions.
import { useState } from 'react'
import { useListSessions } from '../../queries'
import { adminRequest } from '../../queries/admin'
import { en } from '../../i18n'
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
          <section className="flex flex-col gap-2">
            <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">Session · unlock</p>
            <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
              {slice.length === 0 && <p className="text-fg-dim text-xs font-mono text-center py-4">No sessions.</p>}
              {slice.map((s) => (
                <div key={s.id} className="flex flex-wrap items-center gap-2 px-3 py-2">
                  <span className="flex-1 min-w-0 text-sm text-fg truncate">{s.title || 'Untitled'}</span>
                  <span className="text-[10px] font-mono text-fg-dim">{s.date}</span>
                  <span className={`text-[10px] font-mono ${s.locked ? 'text-amber-300/70' : 'text-fg-dim'}`}>{s.locked ? 'locked' : 'draft'}</span>
                  {s.locked && (
                    <ActionButton tone="amber" onClick={() => run(() => adminRequest('POST', `/sessions/${s.id}/unlock`), 'Unlocked')}>
                      Unlock
                    </ActionButton>
                  )}
                  <ActionButton
                    tone="red"
                    onClick={() => {
                      if (window.confirm(en.admin.sessionDeleteConfirm(s.title || 'Untitled', s.date))) {
                        run(
                          () => adminRequest('POST', `/sessions/${s.id}/delete`),
                          'Session deleted + ratings rebuilt',
                          () => refetch(),
                        )
                      }
                    }}
                  >
                    Delete
                  </ActionButton>
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
