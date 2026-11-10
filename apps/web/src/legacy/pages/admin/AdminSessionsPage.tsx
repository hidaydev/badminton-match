// src/pages/admin/AdminSessionsPage.tsx — Admin: unlock & delete sessions.
import { useState } from 'react'
import { useSessionPage } from '../../queries'
import { adminRequest } from '../../queries/admin'
import { useAdmin } from '../../context/AdminContext'
import { t } from '@/i18n'
import AdminPageShell from '../../components/admin/AdminPageShell'
import ActionButton from '../../components/admin/ActionButton'
import Pager from '../../components/admin/Pager'
import { Card } from '../../../components/Card'

const PAGE = 10

export default function AdminSessionsPage() {
  const { isAdminRole } = useAdmin()
  const [page, setPage] = useState(0)
  // Unlock withdraws the session's approval, so it takes a second, explicit tap.
  const [unlockConfirmId, setUnlockConfirmId] = useState<string | null>(null)
  // One server page per table page, so the table can reach sessions older
  // than the server's 500-row cap instead of silently stopping there.
  const { data: sessions, total, refetch, isPlaceholderData } =
    useSessionPage(page, PAGE)

  const slice = sessions

  return (
    <AdminPageShell>
      {({ run }) => (
        <>
          <section className="flex flex-col gap-3">
            <div className="flex items-center justify-between px-0.5">
              <h3 className="text-xs font-semibold text-fg-dim label-meta">{t('admin.sectionSession')}</h3>
              <span className="text-xs font-mono text-fg-dim">
                {t(total === 1 ? 'admin.sessionCountOne' : 'admin.sessionCount', { count: total })}
              </span>
            </div>

            <Card variant="flush" radius="xl" className="divide-y divide-border-subtle shadow-xs">
              {!isPlaceholderData && slice.length === 0 && (
                <p className="text-fg-dim text-xs font-sans text-center py-6">{t('admin.noSessions')}</p>
              )}
              {isPlaceholderData && (
                <p className="text-fg-dim text-xs font-sans text-center py-6">{t('common.loading')}</p>
              )}
              {!isPlaceholderData && slice.map((s) => (
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
                    {s.locked && unlockConfirmId !== s.id && (
                      <ActionButton tone="amber" onClick={() => setUnlockConfirmId(s.id)}>
                        {t('admin.unlock')}
                      </ActionButton>
                    )}
                    {s.locked && unlockConfirmId === s.id && (
                      <>
                        <ActionButton
                          tone="amber"
                          onClick={() => {
                            setUnlockConfirmId(null)
                            void run(
                              () => adminRequest('POST', `/sessions/${s.id}/unlock`),
                              t('admin.unlocked'),
                              () => { void refetch() },
                            )
                          }}
                        >
                          {t('admin.unlockConfirm')}
                        </ActionButton>
                        <ActionButton tone="neutral" onClick={() => setUnlockConfirmId(null)}>
                          {t('admin.cancel')}
                        </ActionButton>
                      </>
                    )}
                    {!isAdminRole && (s.status ?? 'draft') !== 'draft' ? (
                      <span className="text-[11px] text-fg-dim max-w-36 text-right">
                        {t('admin.lockedDeleteAdminOnly')}
                      </span>
                    ) : (
                      <ActionButton
                        tone="red"
                        onClick={() => {
                          if (window.confirm(t('admin.sessionDeleteConfirm', { title: s.title || 'Untitled', date: s.date }))) {
                            void run(
                              () => adminRequest('POST', `/sessions/${s.id}/delete`),
                              t('admin.sessionDeleted'),
                              () => { void refetch() },
                            )
                          }
                        }}
                      >
                        {t('legacy.delete')}
                      </ActionButton>
                    )}
                  </div>
                </div>
              ))}
            </Card>

            <Pager page={page} total={total} onPage={setPage} />
          </section>
        </>
      )}
    </AdminPageShell>
  )
}
