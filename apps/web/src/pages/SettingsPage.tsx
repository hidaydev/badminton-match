import { useCallback, useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { ApiError } from '../auth/api'
import type { CommunityRole } from '../auth/api'
import { useCommunity } from '../community/CommunityContext'
import { updateCommunityConfig } from '../community/api'
import type { CommunityConfig } from '../community/api'
import { useCommunityConfig } from '../community/useCommunityConfig'
import {
  createInvite,
  decideJoinRequest,
  listJoinRequests,
  listMembers,
  removeMember,
  setMemberRole,
} from '../community/adminApi'
import type { Invite, JoinRequest, Member } from '../community/adminApi'
import { t } from '../i18n'
import type { MessageKey } from '../i18n/en'
import { formatDay } from '../utils/day'
import { LoadingState } from '../components/LoadingState'

type Data = {
  slug: string
  members: Member[]
  requests: JoinRequest[]
}

function describe(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.status === 403) return t('admin.error.forbidden')
    if (error.status === 409) return t('admin.error.conflict')
    if (error.status === 400) return t('admin.error.invalid')
  }
  return t('admin.error.failed')
}

const ROLES: readonly CommunityRole[] = ['member', 'host', 'admin']

const ROLE_LABEL: Record<CommunityRole, MessageKey> = {
  admin: 'role.admin',
  host: 'role.host',
  member: 'role.member',
}

/** Everything an admin changes by hand: people, invites and the rating ledger. */
export default function SettingsPage() {
  const { slug = '' } = useParams<{ slug: string }>()
  const { memberships } = useCommunity()
  const membership = memberships.find((candidate) => candidate.slug === slug) ?? null

  const [data, setData] = useState<Data | null>(null)
  const [failure, setFailure] = useState<{ key: string; message: string } | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    if (slug === '') return
    let active = true
    Promise.all([listMembers(slug), listJoinRequests(slug)])
      .then(([members, requests]) => {
        if (!active) return
        setFailure(null)
        setData({ slug, members, requests })
      })
      .catch((problem: unknown) => {
        if (active) setFailure({ key: slug, message: describe(problem) })
      })
    return () => {
      active = false
    }
  }, [slug, attempt])

  const reload = useCallback(() => setAttempt((count) => count + 1), [])

  const run = async (action: () => Promise<unknown>) => {
    setBusy(true)
    setFailure(null)
    try {
      await action()
      reload()
    } catch (problem) {
      setFailure({ key: slug, message: describe(problem) })
    } finally {
      setBusy(false)
    }
  }

  // The previous rows stay on screen while a reload runs: the invite token is
  // shown once, and unmounting the section would throw it away.
  const current = data !== null && data.slug === slug ? data : null
  const error = failure !== null && failure.key === slug ? failure.message : null
  const loading = slug !== '' && current === null && error === null

  return (
    <section className="mx-auto max-w-3xl p-4">
      <h1 className="text-xl font-bold text-fg sm:text-2xl">{t('admin.title')}</h1>
      <p className="mt-1 text-sm text-fg-dim">{membership?.name ?? slug}</p>

      {loading && <LoadingState label={t('app.loading')} rows={1} />}
      {error !== null && (
        <p role="alert" aria-live="polite" className="mt-4 text-sm text-error">
          {error}
        </p>
      )}
      {current !== null && (
        <>
          <Members
            slug={slug}
            members={current.members}
            busy={busy}
            onRun={run}
          />
          <Invites slug={slug} busy={busy} onRun={run} />
          <JoinRequests
            slug={slug}
            requests={current.requests}
            busy={busy}
            onRun={run}
          />
          <CommunitySettings
            key={slug}
            slug={slug}
            canEdit={membership?.role === 'admin'}
          />
        </>
      )}
    </section>
  )
}

type ConfigField = {
  key: string
  label: MessageKey
  kind: 'text' | 'number' | 'bool'
}

/** The values a community may narrow by hand. */
const CONFIG_FIELDS: readonly ConfigField[] = [
  { key: 'community.default_timezone', label: 'community.setting.timezone', kind: 'text' },
  { key: 'community.invite_ttl_days', label: 'community.setting.inviteTtl', kind: 'number' },
  { key: 'community.directory_enabled', label: 'community.setting.directory', kind: 'bool' },
  { key: 'community.join_requests_enabled', label: 'community.setting.joinRequests', kind: 'bool' },
]

function asDraft(field: ConfigField, value: unknown): string | boolean {
  if (field.kind === 'bool') return value === true
  return value === undefined || value === null ? '' : String(value)
}

function fromDraft(field: ConfigField, raw: string | boolean | undefined): unknown {
  if (field.kind === 'bool') return raw === true
  if (field.kind === 'number') return Number(raw)
  return String(raw ?? '').trim()
}

/**
 * The values an admin can narrow. The server rejects anything above the platform
 * value, so the screen shows the source of each one instead of pretending the
 * community owns it.
 */
function CommunitySettings({ slug, canEdit }: { slug: string; canEdit: boolean }) {
  const { config, loading, error } = useCommunityConfig(slug)
  const [saved, setSaved] = useState<CommunityConfig | null>(null)
  const [edits, setEdits] = useState<Record<string, string | boolean>>({})
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<string | null>(null)

  if (loading && config === null) {
    return <LoadingState label={t('community.settings')} rows={2} />
  }
  if (error !== null && config === null) {
    return (
      <p role="alert" className="mt-4 text-sm text-error">
        {t('community.error.load')}
      </p>
    )
  }
  if (config === null) return null

  // A saved response replaces the loaded one; untouched fields still edit from
  // the server value, so the form never lags behind a write.
  const values = saved ?? config
  const fieldValue = (field: ConfigField): string | boolean =>
    field.key in edits ? edits[field.key] : asDraft(field, values[field.key]?.value)

  const submit = async () => {
    const patch: Record<string, unknown> = {}
    for (const field of CONFIG_FIELDS) {
      const next = fromDraft(field, fieldValue(field))
      if (JSON.stringify(next) !== JSON.stringify(values[field.key]?.value)) {
        patch[field.key] = next
      }
    }
    if (Object.keys(patch).length === 0) {
      setMessage(t('community.settings.saved'))
      return
    }
    setBusy(true)
    setMessage(null)
    try {
      const updated = await updateCommunityConfig(slug, patch)
      setSaved(updated)
      setEdits({})
      setMessage(t('community.settings.saved'))
    } catch (problem) {
      setMessage(describe(problem))
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="mt-8">
      <h2 className="text-sm font-semibold text-fg">{t('community.settings')}</h2>
      <p className="mt-1 text-xs text-fg-dim">{t('community.settingsHint')}</p>
      <form
        className="mt-3 space-y-3"
        onSubmit={(event) => {
          event.preventDefault()
          void submit()
        }}
      >
        {CONFIG_FIELDS.map((field) => {
          const entry = values[field.key]
          const id = `config-${field.key}`
          return (
            <div key={field.key} className="flex flex-wrap items-center justify-between gap-2">
              <span className="flex items-baseline gap-2">
                <label htmlFor={id} className="text-sm text-fg">
                  {t(field.label)}
                </label>
                {entry !== undefined && (
                  <span className="text-xs text-fg-dim">
                    {t(entry.source === 'community' ? 'community.source.community' : 'community.source.platform')}
                  </span>
                )}
              </span>
              {field.kind === 'bool' ? (
                <input
                  id={id}
                  type="checkbox"
                  checked={fieldValue(field) === true}
                  disabled={!canEdit || busy}
                  onChange={(event) =>
                    setEdits((current) => ({ ...current, [field.key]: event.target.checked }))
                  }
                  className="h-5 w-5 rounded border border-border bg-elevated text-accent focus-visible:ring-2 focus-visible:ring-accent"
                />
              ) : (
                <input
                  id={id}
                  type={field.kind === 'number' ? 'number' : 'text'}
                  value={String(fieldValue(field) ?? '')}
                  disabled={!canEdit || busy}
                  onChange={(event) =>
                    setEdits((current) => ({ ...current, [field.key]: event.target.value }))
                  }
                  className="min-h-11 w-40 rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-60"
                />
              )}
            </div>
          )
        })}
        {canEdit && (
          <div className="flex flex-wrap items-center gap-3">
            <button
              type="submit"
              disabled={busy}
              className="min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
            >
              {t('community.settings.save')}
            </button>
            <span role="status" aria-live="polite" className="text-xs text-fg-dim">
              {message ?? ''}
            </span>
          </div>
        )}
      </form>
    </section>
  )
}

type Run = (action: () => Promise<unknown>) => Promise<void>

function Members({
  slug,
  members,
  busy,
  onRun,
}: {
  slug: string
  members: Member[]
  busy: boolean
  onRun: Run
}) {
  return (
    <section className="mt-6">
      <h2 className="text-sm font-semibold text-fg">{t('admin.members')}</h2>
      <ul className="mt-2 space-y-2">
        {members.map((member) => (
          <MemberRow
            key={member.userId}
            slug={slug}
            member={member}
            busy={busy}
            onRun={onRun}
          />
        ))}
      </ul>
    </section>
  )
}

function MemberRow({
  slug,
  member,
  busy,
  onRun,
}: {
  slug: string
  member: Member
  busy: boolean
  onRun: Run
}) {
  const [confirming, setConfirming] = useState(false)

  return (
    <li className="rounded-xl border border-border-subtle bg-surface p-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <span className="min-w-0">
          <span className="block truncate text-sm text-fg">{member.displayName}</span>
          <span className="font-mono text-[10px] text-fg-dim">
            {formatDay(member.joinedAt)}
          </span>
        </span>
        <span className="flex items-center gap-2">
          <label className="text-xs text-fg-dim">
            <span className="sr-only">{t('admin.members.role', { name: member.displayName })}</span>
            <select
              value={member.role}
              disabled={busy}
              onChange={(event) =>
                void onRun(() =>
                  setMemberRole(slug, member.userId, event.target.value as CommunityRole),
                )
              }
              className="min-h-11 rounded-xl border border-border bg-elevated px-2 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
            >
              {ROLES.map((role) => (
                <option key={role} value={role}>
                  {t(ROLE_LABEL[role])}
                </option>
              ))}
            </select>
          </label>
          {!confirming && (
            <button
              type="button"
              disabled={busy}
              onClick={() => setConfirming(true)}
              className="min-h-11 rounded-xl border border-border px-3 text-xs text-error hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
            >
              {t('admin.members.remove')}
            </button>
          )}
        </span>
      </div>
      {confirming && (
        <div
          role="group"
          aria-label={t('admin.members.removeConfirm', { name: member.displayName })}
          className="mt-2 flex flex-wrap gap-2"
        >
          <button
            type="button"
            disabled={busy}
            onClick={() => void onRun(() => removeMember(slug, member.userId))}
            className="min-h-11 rounded-xl border border-border px-3 text-xs text-error hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
          >
            {t('admin.members.removeConfirmAction')}
          </button>
          <button
            type="button"
            onClick={() => setConfirming(false)}
            className="min-h-11 rounded-xl border border-border px-3 text-xs text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent"
          >
            {t('admin.cancel')}
          </button>
        </div>
      )}
    </li>
  )
}

function Invites({
  slug,
  busy,
  onRun,
}: {
  slug: string
  busy: boolean
  onRun: Run
}) {
  const [email, setEmail] = useState('')
  const [role, setRole] = useState<CommunityRole>('member')
  const [invite, setInvite] = useState<Invite | null>(null)

  return (
    <section className="mt-8">
      <h2 className="text-sm font-semibold text-fg">{t('admin.invites')}</h2>
      <p className="mt-1 text-xs text-fg-dim">{t('admin.invites.hint')}</p>
      <form
        className="mt-2 grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto_auto] sm:items-end"
        onSubmit={(event) => {
          event.preventDefault()
          if (email.trim() === '') return
          void onRun(async () => {
            const created = await createInvite(slug, email.trim(), role)
            setInvite(created)
            setEmail('')
          })
        }}
      >
        <label className="min-w-0 flex-1 text-xs text-fg-dim">
          {t('admin.invites.email')}
          <input
            type="email"
            required
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
          />
        </label>
        <label className="text-xs text-fg-dim">
          {t('admin.invites.role')}
          <select
            value={role}
            onChange={(event) => setRole(event.target.value as CommunityRole)}
            className="mt-1 min-h-11 rounded-xl border border-border bg-elevated px-2 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
          >
            {ROLES.map((value) => (
              <option key={value} value={value}>
                {t(ROLE_LABEL[value])}
              </option>
            ))}
          </select>
        </label>
        <button
          type="submit"
          disabled={busy || email.trim() === ''}
          className="min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
        >
          {t('admin.invites.create')}
        </button>
      </form>
      {invite !== null && (
        <p className="mt-2 rounded-xl border border-border-subtle bg-surface p-3 text-sm text-fg">
          {t('admin.invites.created', { days: invite.expiresInDays })}
          <span className="mt-1 block font-mono text-xs break-all text-fg-dim">
            {invite.token}
          </span>
        </p>
      )}
    </section>
  )
}

function JoinRequests({
  slug,
  requests,
  busy,
  onRun,
}: {
  slug: string
  requests: JoinRequest[]
  busy: boolean
  onRun: Run
}) {
  return (
    <section className="mt-8">
      <h2 className="text-sm font-semibold text-fg">{t('admin.requests')}</h2>
      {requests.length === 0 ? (
        <p className="mt-2 text-sm text-fg-dim">{t('admin.requests.empty')}</p>
      ) : (
        <ul className="mt-2 space-y-2">
          {requests.map((request) => (
            <li
              key={request.id}
              className="rounded-xl border border-border-subtle bg-surface p-3"
            >
              <p className="text-sm text-fg">{request.displayName}</p>
              <p className="font-mono text-[10px] text-fg-dim">
                {formatDay(request.createdAt)}
              </p>
              <div className="mt-2 flex flex-wrap gap-2">
                <button
                  type="button"
                  disabled={busy}
                  onClick={() =>
                    void onRun(() => decideJoinRequest(slug, request.id, 'approve'))
                  }
                  className="min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
                >
                  {t('admin.requests.approve')}
                </button>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() =>
                    void onRun(() => decideJoinRequest(slug, request.id, 'reject'))
                  }
                  className="min-h-11 rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
                >
                  {t('admin.requests.reject')}
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
