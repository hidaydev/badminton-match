// src/pages/admin/AdminTournamentsPage.tsx — Admin: list & delete tournaments.
import { useListTournaments } from '../../queries'
import { adminRequest } from '../../queries/admin'
import { en } from '../../i18n'
import AdminPageShell from '../../components/admin/AdminPageShell'
import ActionButton from '../../components/admin/ActionButton'

export default function AdminTournamentsPage() {
  const { data: tournaments, refetch } = useListTournaments()

  return (
    <AdminPageShell>
      {({ run }) => (
        <>
          <section className="flex flex-col gap-2">
            <p className="text-[10px] font-mono text-amber-500/80 uppercase tracking-wider">Tournament · delete</p>
            <div className="bg-surface border border-border-subtle rounded-lg divide-y divide-border-subtle overflow-hidden">
              {(tournaments ?? []).length === 0 && <p className="text-fg-dim text-xs font-mono text-center py-4">No tournaments.</p>}
              {(tournaments ?? []).map((t2) => (
                <div key={t2.id} className="flex flex-wrap items-center gap-2 px-3 py-2">
                  <span className="flex-1 min-w-0 text-sm text-fg truncate">{t2.name || 'Untitled Tournament'}</span>
                  <span className="text-[10px] font-mono text-fg-dim">{t2.date}</span>
                  <span className={`text-[10px] font-mono ${t2.format === 'team' ? 'text-accent' : 'text-fg-dim'}`}>{t2.format}</span>
                  <ActionButton
                    tone="red"
                    onClick={() => {
                      if (window.confirm(en.admin.tournamentDeleteConfirm(t2.name || 'Untitled Tournament'))) {
                        run(
                          () => adminRequest('POST', `/tournaments/${t2.id}/delete`),
                          'Tournament deleted + ratings rebuilt',
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
          </section>
        </>
      )}
    </AdminPageShell>
  )
}
