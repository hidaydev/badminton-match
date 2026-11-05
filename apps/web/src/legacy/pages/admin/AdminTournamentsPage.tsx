import { useState } from 'react'
import { useListTournaments } from '../../queries'
import { adminRequest } from '../../queries/admin'
import { t, en } from '../../i18n'
import AdminPageShell from '../../components/admin/AdminPageShell'
import ActionButton from '../../components/admin/ActionButton'
import Pager from '../../components/admin/Pager'

const PAGE = 10

export default function AdminTournamentsPage() {
  const [page, setPage] = useState(0)
  const { data: tournaments, refetch } = useListTournaments()

  const slice = (tournaments ?? []).slice(page * PAGE, page * PAGE + PAGE)

  return (
    <AdminPageShell>
      {({ run }) => (
        <>
          <section className="flex flex-col gap-3">
            <div className="flex items-center justify-between px-0.5">
              <p className="text-xs font-semibold text-fg-dim uppercase tracking-wider">{t('admin.sectionTournament')}</p>
              <span className="text-xs font-mono text-fg-dim">{(tournaments ?? []).length} tournaments</span>
            </div>

            <div className="bg-surface border border-border-subtle rounded-xl divide-y divide-border-subtle overflow-hidden shadow-xs">
              {slice.length === 0 && <p className="text-fg-dim text-xs font-sans text-center py-6">{t('admin.noTournaments')}</p>}
              {slice.map((t2) => (
                <div key={t2.id} className="flex items-center justify-between gap-3 px-3.5 py-2.5 hover:bg-elevated/30 transition-colors">
                  <div className="flex flex-col min-w-0">
                    <span className="text-sm font-medium text-fg truncate">{t2.name || 'Untitled Tournament'}</span>
                    <div className="flex items-center gap-2 text-[11px] text-fg-dim font-mono mt-0.5">
                      <span>{t2.date}</span>
                      <span>·</span>
                      <span className={t2.format === 'team' ? 'text-accent font-medium font-sans' : 'text-fg-dim font-sans'}>
                        {t2.format === 'team' ? 'Team Cup' : 'Classic'}
                      </span>
                    </div>
                  </div>

                  <div className="flex items-center gap-1.5 shrink-0">
                    <ActionButton
                      tone="red"
                      onClick={() => {
                        if (window.confirm(en.admin.tournamentDeleteConfirm(t2.name || 'Untitled Tournament'))) {
                          run(
                            () => adminRequest('POST', `/tournaments/${t2.id}/delete`),
                            t('admin.tournamentDeleted'),
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

            <Pager page={page} total={(tournaments ?? []).length} onPage={setPage} />
          </section>
        </>
      )}
    </AdminPageShell>
  )
}
