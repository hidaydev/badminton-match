import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { ApiError } from '../auth/api'
import type { CommunityRole } from '../auth/api'
import { useAuth } from '../auth/AuthContext'
import { t } from '../i18n'
import type { MessageKey } from '../i18n/en'
import { createCommunity } from '../community/ownerApi'
import type { CreatedCommunity } from '../community/ownerApi'

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
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [created, setCreated] = useState<CreatedCommunity | null>(null)

  const submit = async () => {
    setBusy(true)
    setError(null)
    setCreated(null)
    try {
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
    } catch (problem) {
      setError(describe(problem))
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <header className="sticky top-0 z-10 border-b border-border-subtle bg-surface pt-[env(safe-area-inset-top)]">
        <div className="mx-auto flex max-w-3xl items-center gap-2 px-3 py-2.5">
          <button
            onClick={() => navigate(-1)}
            className="-ml-1.5 -my-1.5 h-11 w-11 shrink-0 flex items-center justify-center rounded-lg text-fg-dim transition-all hover:text-fg active:scale-90"
            aria-label={t('shell.back')}
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M15 18l-6-6 6-6" />
            </svg>
          </button>
          <Link to="/" className="flex items-center gap-2">
            <img src="/logo-192.png" alt="" className="h-6 w-6 shrink-0 object-contain" />
            <span className="text-sm font-bold tracking-tight text-fg">{t('shell.brand')}</span>
          </Link>
        </div>
      </header>
      <section className="mx-auto max-w-3xl p-4">
      <h1 className="text-xl font-bold text-fg sm:text-2xl">{t('setup.title')}</h1>
      <p className="mt-1 text-sm text-fg-dim">{t('setup.subtitle')}</p>

      <h2 className="mt-6 text-sm font-semibold text-fg">{t('setup.mine')}</h2>
      {memberships.length === 0 ? (
        <p className="mt-2 text-sm text-fg-dim">{t('setup.mine.empty')}</p>
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
        <form
          className="mt-8 rounded-2xl border border-border-subtle bg-surface p-4"
          onSubmit={(event) => {
            event.preventDefault()
            void submit()
          }}
        >
          <h2 className="text-sm font-semibold text-fg">{t('setup.create')}</h2>
          {error !== null && (
            <p role="alert" className="mt-2 text-sm text-error">
              {error}
            </p>
          )}
          {created !== null && (
            <p role="status" className="mt-2 text-sm text-fg">
              {t('setup.created', { name: created.name })}
              <span className="mt-1 block text-xs text-fg-dim">{t('setup.created.hint')}</span>
            </p>
          )}
          <div className="mt-3 grid gap-3 sm:grid-cols-2">
            <label className="text-xs text-fg-dim">
              {t('setup.slug')}
              <input
                required
                value={slug}
                onChange={(event) => setSlug(event.target.value)}
                pattern="[a-z0-9-]{2,40}"
                placeholder={t('setup.slug.placeholder')}
                className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
              />
            </label>
            <label className="text-xs text-fg-dim">
              {t('setup.name')}
              <input
                required
                value={name}
                onChange={(event) => setName(event.target.value)}
                className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
              />
            </label>
            <label className="text-xs text-fg-dim">
              {t('setup.adminEmail')}
              <input
                required
                type="email"
                value={adminEmail}
                onChange={(event) => setAdminEmail(event.target.value)}
                className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
              />
            </label>
            <label className="text-xs text-fg-dim">
              {t('setup.timezone')}
              <input
                value={timezone}
                onChange={(event) => setTimezone(event.target.value)}
                placeholder={t('setup.timezone.placeholder')}
                className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
              />
            </label>
          </div>
          <p className="mt-2 text-xs text-fg-dim">{t('setup.adminEmail.hint')}</p>
          <button
            type="submit"
            disabled={busy || slug.trim() === '' || name.trim() === '' || adminEmail.trim() === ''}
            className="mt-3 min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
          >
            {t('setup.submit')}
          </button>
        </form>
      )}
    </section>
    </>
  )
}
