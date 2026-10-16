// src/pages/admin/AdminTournamentsPage.tsx — Admin: list & delete tournaments.
import { useListTournaments } from '../../queries'
import { adminRequest } from '../../queries/admin'
import { t, en } from '../../i18n'
import AdminPageShell from '../../components/admin/AdminPageShell'
import ActionButton from '../../components/admin/ActionButton'

export default function AdminTournamentsPage() {
  const { data: tournaments, refetch } = useListTournaments()

  return (
    <AdminPageShell>
      {({ run }) => (
        <>
          <section className="flex flex-col gap-2.5">
            <div className="flex items-center justify-between px-1">
              <p className="text-xs font-semibold text-fg-dim uppercase tracking-wider">{t('admin.sectionTournament')}</p>
              <span className="text-xs font-mono text-fg-dim">{(tournaments ?? []).length} tournaments</span>
            </div>

            <div className="bg-surface border border-border-subtle rounded-xl divide-y divide-border-subtle overflow-hidden shadow-xs">
              {(tournaments ?? []).length === 0 && (
                <div className="flex flex-col items-center justify-center py-8 text-center gap-2">
                  <span className="text-2xl">🏆</span>
                  <p className="text-fg-dim text-xs font-sans">{t('admin.noTournaments')}</p>
                </div>
              )}
              {(tournaments ?? []).map((t2) => (
                <div key={t2.id} className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 px-4 py-3 hover:bg-elevated/20 transition-colors">
                  <div className="flex items-start gap-3 min-w-0">
                    <span className="text-lg shrink-0 mt-0.5">🏆</span>
                    <div className="flex flex-col min-w-0">
                      <div className="flex items-center gap-2 flex-wrap">
                        <span className="text-sm font-semibold text-fg truncate">{t2.name || 'Untitled Tournament'}</span>
                        <span className={`text-[10px] font-medium px-2 py-0.5 rounded-full border ${t2.format === 'team' ? 'bg-accent/15 text-accent border-accent/30 font-semibold' : 'bg-elevated border-border-subtle text-fg-dim'}`}>
                          {t2.format === 'team' ? 'Team Cup' : 'Classic'}
                        </span>
                      </div>
                      <div className="flex items-center gap-2 mt-0.5 text-[11px] text-fg-dim font-mono">
                        <span>{t2.date}</span>
                      </div>
                    </div>
                  </div>

                  <div className="flex items-center gap-2 self-end sm:self-auto shrink-0">
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
          </section>
        </>
      )}
    </AdminPageShell>
  )
}
