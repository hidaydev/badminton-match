import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { ApiError } from '../auth/api'
import type { CommunityRole } from '../auth/api'
import { useAuth } from '../auth/AuthContext'
import { t } from '../i18n'
import type { MessageKey } from '../i18n/en'
import { Button } from '../components/Button'
import { EmptyState } from '../components/EmptyState'
import { CollapsiblePanel } from '../components/CollapsiblePanel'
import { useAsyncAction } from '../hooks/useAsyncAction'
import { ErrorText } from '../components/ErrorText'
import { Field, Input } from '../components/Field'
import { PageHeader } from '../components/PageHeader'
import { createCommunity } from '../community/ownerApi'
import type { CreatedCommunity } from '../community/ownerApi'
import Icon from '../components/Icon'
import { PAGE_COLUMN } from '../components/Page'

const ROLE_LABEL: Record<CommunityRole, MessageKey> = {
  admin: 'role.admin',
  host: 'role.host',
  member: 'role.member',
}

function describe(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.status === 403) return t('setup.error.forbidden')
    if (error.status === 409) return t('setup.error.slugTaken')
    if (error.status === 400) return t('setup.error.invalid')
  }
  return t('setup.error.failed')
}

/** Platform owner: open a new community and see the ones this account is in. */
export default function SetupPage() {
  const { user, memberships } = useAuth()
  const navigate = useNavigate()
  const [slug, setSlug] = useState('')
  const [name, setName] = useState('')
  const [adminEmail, setAdminEmail] = useState('')
  const [timezone, setTimezone] = useState('')
  const [created, setCreated] = useState<CreatedCommunity | null>(null)

  const submitAction = useAsyncAction(
    async () => {
      setCreated(null)
      const community = await createCommunity({
        slug: slug.trim(),
        name: name.trim(),
        adminEmail: adminEmail.trim(),
        ...(timezone.trim() === '' ? {} : { timezone: timezone.trim() }),
      })
      setCreated(community)
      setSlug('')
      setName('')
      setAdminEmail('')
      setTimezone('')
    },
    { describeError: describe },
  )
  const { busy } = submitAction
  const error = submitAction.error

  const submit = async () => {
    await submitAction.run()
  }

  return (
    <>
      <header className="sticky top-0 z-10 border-b border-border-subtle bg-surface pt-[env(safe-area-inset-top)]">
        <div className={`flex ${PAGE_COLUMN} items-center gap-2 py-2.5`}>
          <button
            onClick={() => navigate(-1)}
            className="-ml-1.5 -my-1.5 h-11 w-11 shrink-0 flex items-center justify-center rounded-lg text-fg-dim transition-[color,transform] hover:text-fg active:scale-90"
            aria-label={t('shell.back')}
          >
            <Icon name="chevron-left" size={18} />
          </button>
          <Link to="/" className="flex items-center gap-2">
            <img src="/logo-192.png" alt="" className="h-6 w-6 shrink-0 object-contain" />
            <span className="text-sm font-bold tracking-tight text-fg">{t('shell.brand')}</span>
          </Link>
        </div>
      </header>
      <main className={`${PAGE_COLUMN} py-4`}>
      <PageHeader title={t('setup.title')} subtitle={t('setup.subtitle')} />

      <h2 className="mt-6 text-sm font-semibold text-fg">{t('setup.mine')}</h2>
      {memberships.length === 0 ? (
        <EmptyState title={t('setup.mine.empty')} />
      ) : (
        <ul className="mt-2 space-y-2">
          {memberships.map((membership) => (
            <li key={membership.id}>
              <Link
                to={`/c/${encodeURIComponent(membership.slug)}`}
                className="flex min-h-11 items-center justify-between gap-3 rounded-xl border border-border-subtle bg-surface px-4 py-3 hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent"
              >
                <span className="truncate text-sm text-fg">{membership.name}</span>
                <span className="shrink-0 text-xs text-fg-dim">
                  {t(ROLE_LABEL[membership.role])}
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}

      {user?.platformOwner === true && (
        <CollapsiblePanel className="mt-8" title={t('setup.create')}>
          <form
            onSubmit={async (event) => {
              event.preventDefault()
              await submit()
            }}
          >
            {error !== null && (
              <ErrorText className="mt-2">{error}</ErrorText>
            )}
            {created !== null && (
              <p role="status" className="mt-2 text-sm text-fg">
                {t('setup.created', { name: created.name })}
                <span className="mt-1 block text-xs text-fg-dim">{t('setup.created.hint')}</span>
              </p>
            )}
            <div className="mt-3 grid gap-3 sm:grid-cols-2">
              <Field label={t('setup.slug')}>
                <Input
                  required
                  value={slug}
                  onChange={(event) => setSlug(event.target.value)}
                  pattern="[a-z0-9-]{2,40}"
                  placeholder={t('setup.slug.placeholder')}
                />
              </Field>
              <Field label={t('setup.name')}>
                <Input
                  required
                  value={name}
                  onChange={(event) => setName(event.target.value)}
                />
              </Field>
              <Field label={t('setup.adminEmail')}>
                <Input
                  required
                  type="email"
                  value={adminEmail}
                  onChange={(event) => setAdminEmail(event.target.value)}
                />
              </Field>
              <Field label={t('setup.timezone')}>
                <Input
                  value={timezone}
                  onChange={(event) => setTimezone(event.target.value)}
                  placeholder={t('setup.timezone.placeholder')}
                />
              </Field>
            </div>
            <p className="mt-2 text-xs text-fg-dim">{t('setup.adminEmail.hint')}</p>
            <Button
              type="submit"
              className="mt-3"
              disabled={busy || slug.trim() === '' || name.trim() === '' || adminEmail.trim() === ''}
            >
              {t('setup.submit')}
            </Button>
          </form>
        </CollapsiblePanel>
      )}
    </main>
    </>
  )
}
