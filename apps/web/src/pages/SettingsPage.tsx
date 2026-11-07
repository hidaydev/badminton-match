import { useCallback, useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { ApiError } from '../auth/api'
import type { CommunityRole } from '../auth/api'
import { useCommunity } from '../community/CommunityContext'
import { updateCommunityConfig, fetchScoringPresets } from '../community/api'
import type { CommunityConfig, CommunityConfigEntry, ScoringPreset } from '../community/api'
import { useCommunityConfig } from '../community/useCommunityConfig'
import {
  createInvite,
  decideJoinRequest,
  listJoinRequests,
  listMembers,
  listPendingClaims,
  removeMember,
  setMemberRole,
} from '../community/adminApi'
import type { Invite, JoinRequest, Member, PendingClaim } from '../community/adminApi'
import { decideClaim } from '../players/api'
import { t } from '../i18n'
import type { MessageKey } from '../i18n/en'
import { formatDay } from '../utils/day'
import { ErrorText } from '../components/ErrorText'
import { Field, Input } from '../components/Field'
import { LoadingState } from '../components/LoadingState'

type Data = {
  slug: string
  members: Member[]
  requests: JoinRequest[]
  claims: PendingClaim[]
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
    Promise.all([listMembers(slug), listJoinRequests(slug), listPendingClaims(slug)])
      .then(([members, requests, claims]) => {
        if (!active) return
        setFailure(null)
        setData({ slug, members, requests, claims })
      })
      .catch((problem: unknown) => {
        if (active) setFailure({ key: slug, message: describe(problem) })
      })
    return () => {
      active = false
    }
  }, [slug, attempt])

  const reload = useCallback(() => setAttempt((count) => count + 1), [])

  const run = async (action: () => Promise<unknown>): Promise<boolean> => {
    setBusy(true)
    setFailure(null)
    try {
      await action()
      reload()
      return true
    } catch (problem) {
      setFailure({ key: slug, message: describe(problem) })
      return false
    } finally {
      setBusy(false)
    }
  }

  // The previous rows stay on screen while a reload runs: the invite token is
  // shown once, and unmounting the section would throw it away.
  const current = data !== null && data.slug === slug ? data : null
  const error = failure !== null && failure.key === slug ? failure.message : null
  const loading = slug !== '' && current === null && error === null
  const canEdit = membership?.role === 'admin'

  return (
    <section className="mx-auto max-w-3xl p-4">
      <h1 className="text-xl font-bold text-fg sm:text-2xl">{t('admin.title')}</h1>
      <p className="mt-1 text-sm text-fg-dim">{membership?.name ?? slug}</p>

      {loading && <LoadingState label={t('app.loading')} rows={1} />}
      {error !== null && (
        <ErrorText className="mt-4">{error}</ErrorText>
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
          {canEdit && (
            <PendingClaims
              slug={slug}
              claims={current.claims}
              onReload={reload}
            />
          )}
          <CommunitySettings
            key={slug}
            slug={slug}
            canEdit={canEdit}
          />
        </>
      )}
    </section>
  )
}

type ConfigField = {
  key: string
  label: MessageKey
  kind: 'text' | 'number' | 'bool' | 'select'
}

/** The values a community may narrow by hand. */
const CONFIG_FIELDS: readonly ConfigField[] = [
  { key: 'community.default_timezone', label: 'community.setting.timezone', kind: 'text' },
  { key: 'community.invite_ttl_days', label: 'community.setting.inviteTtl', kind: 'number' },
  { key: 'community.directory_enabled', label: 'community.setting.directory', kind: 'bool' },
  { key: 'community.join_requests_enabled', label: 'community.setting.joinRequests', kind: 'bool' },
  { key: 'session.default_scoring_preset', label: 'community.setting.scoringPreset', kind: 'select' },
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
 * A switch the server says the community cannot turn on. The API decides this
 * per key (`widenable`), so the screen never hardcodes which flags are opt-in;
 * a response without the field counts as not widenable and fails safe.
 */
function pinnedByPlatform(
  field: ConfigField,
  entry: CommunityConfigEntry | undefined,
): boolean {
  return (
    field.kind === 'bool' &&
    entry !== undefined &&
    entry.source === 'platform' &&
    entry.value === false &&
    entry.widenable !== true
  )
}

/** The server explains a refused write in `detail`; show it when it is there. */
function describeSave(error: unknown): string {
  if (error instanceof ApiError && error.detail !== null) return error.detail
  return describe(error)
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
  const [presets, setPresets] = useState<ScoringPreset[]>([])

  // The list is reference data; a failure here leaves the select empty rather
  // than breaking the rest of the settings screen.
  useEffect(() => {
    if (slug === '') return
    let active = true
    fetchScoringPresets(slug)
      .then((list) => { if (active) setPresets(list) })
      .catch(() => { if (active) setPresets([]) })
    return () => { active = false }
  }, [slug])

  if (loading && config === null) {
    return <LoadingState label={t('community.settings')} rows={2} />
  }
  if (error !== null && config === null) {
    return <ErrorText className="mt-4">{t('community.error.load')}</ErrorText>
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
      // A pinned switch is locked on screen; keeping it out of the body means
      // the form never asks the server for a write it has already refused.
      if (pinnedByPlatform(field, values[field.key])) continue
      const next = fromDraft(field, fieldValue(field))
      const current = values[field.key]?.value
      // A key the server did not report and an untouched empty draft are the
      // same state; sending "" would ask to clear a setting that was never set.
      if (current === undefined && next === '') continue
      if (JSON.stringify(next) !== JSON.stringify(current)) {
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
      setMessage(describeSave(problem))
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
          const pinned = pinnedByPlatform(field, entry)
          const reasonId = `${id}-locked`
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
                  disabled={!canEdit || busy || pinned}
                  aria-describedby={pinned ? reasonId : undefined}
                  onChange={(event) => {
                    // Disabled in the DOM already; ignoring a synthetic change
                    // keeps the draft from disagreeing with the lock.
                    if (pinned) return
                    setEdits((current) => ({
                      ...current,
                      [field.key]: event.target.checked,
                    }))
                  }}
                  className="h-5 w-5 rounded border border-border bg-elevated text-accent focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-60"
                />
              ) : field.kind === 'select' ? (
                <select
                  id={id}
                  value={String(fieldValue(field) ?? '')}
                  disabled={!canEdit || busy}
                  onChange={(event) =>
                    setEdits((current) => ({ ...current, [field.key]: event.target.value }))
                  }
                  className="min-h-11 w-40 rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-60"
                >
                  {presets.map((preset) => (
                    <option key={preset.id} value={preset.id}>{preset.label}</option>
                  ))}
                  {presets.every((preset) => preset.id !== String(fieldValue(field))) && (
                    <option value={String(fieldValue(field) ?? '')}>
                      {String(fieldValue(field) ?? '')}
                    </option>
                  )}
                </select>
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
              {pinned && (
                <p id={reasonId} className="w-full text-xs text-fg-dim">
                  {t('community.setting.lockedByPlatform')}
                </p>
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

type Run = (action: () => Promise<unknown>) => Promise<boolean>

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
        <Field label={t('admin.invites.email')} className="min-w-0 flex-1">
          <Input
            type="email"
            required
            value={email}
            onChange={(event) => setEmail(event.target.value)}
          />
        </Field>
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
          <a
            href={`/invites/${encodeURIComponent(invite.token)}`}
            className="mt-1 block min-h-11 break-all font-mono text-xs text-accent hover:underline focus-visible:ring-2 focus-visible:ring-accent"
          >
            {`${window.location.origin}/invites/${invite.token}`}
          </a>
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
  // A request joins as a member unless the admin says otherwise; the role is
  // sent with the approval, and the granted role is echoed back afterwards.
  const [roles, setRoles] = useState<Record<string, CommunityRole>>({})
  const [granted, setGranted] = useState<{ name: string; role: CommunityRole } | null>(
    null,
  )

  const approve = async (request: JoinRequest) => {
    const role = roles[request.id] ?? 'member'
    // A stale banner from an earlier approval must not sit beside a new error.
    setGranted(null)
    if (await onRun(() => decideJoinRequest(slug, request.id, 'approve', role))) {
      setGranted({ name: request.displayName, role })
    }
  }

  const reject = async (request: JoinRequest) => {
    setGranted(null)
    await onRun(() => decideJoinRequest(slug, request.id, 'reject'))
  }

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
              <div className="mt-2 flex flex-wrap items-end gap-2">
                <label className="text-xs text-fg-dim">
                  <span className="sr-only">
                    {t('admin.requests.roleOf', { name: request.displayName })}
                  </span>
                  <select
                    value={roles[request.id] ?? 'member'}
                    disabled={busy}
                    onChange={(event) =>
                      setRoles((current) => ({
                        ...current,
                        [request.id]: event.target.value as CommunityRole,
                      }))
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
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => void approve(request)}
                  className="min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
                >
                  {t('admin.requests.approve')}
                </button>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => void reject(request)}
                  className="min-h-11 rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
                >
                  {t('admin.requests.reject')}
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}
      {granted !== null && (
        <p role="status" aria-live="polite" className="mt-2 text-sm text-fg-dim">
          {t('admin.requests.granted', {
            name: granted.name,
            role: t(ROLE_LABEL[granted.role]),
          })}
        </p>
      )}
    </section>
  )
}

/**
 * A pending claim is invisible until someone opens that player's page, so the
 * queue is the only way an admin discovers that an account is waiting. A
 * decision refreshes the page load, which leaves the other sections as they
 * were, because the rows are swapped only once the new read lands.
 */
function PendingClaims({
  slug,
  claims,
  onReload,
}: {
  slug: string
  claims: PendingClaim[]
  onReload: () => void
}) {
  const [pendingId, setPendingId] = useState<string | null>(null)
  const [failure, setFailure] = useState<string | null>(null)

  const decide = async (claim: PendingClaim, decision: 'approve' | 'reject') => {
    setPendingId(claim.claimId)
    setFailure(null)
    try {
      await decideClaim(slug, claim.playerId, claim.claimId, { decision })
      onReload()
    } catch (problem) {
      setFailure(describeSave(problem))
    } finally {
      setPendingId(null)
    }
  }

  return (
    <section className="mt-8">
      <h2 className="text-sm font-semibold text-fg">{t('admin.claims')}</h2>
      <p className="mt-1 text-xs text-fg-dim">{t('admin.claims.hint')}</p>
      {claims.length === 0 ? (
        <p className="mt-2 text-sm text-fg-dim">{t('admin.claims.empty')}</p>
      ) : (
        <ul className="mt-2 space-y-2">
          {claims.map((claim) => (
            <li
              key={claim.claimId}
              className="rounded-xl border border-border-subtle bg-surface p-3"
            >
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="min-w-0">
                  <span className="block truncate text-sm text-fg">
                    {claim.playerName}
                  </span>
                  <span className="block text-xs text-fg-dim">
                    {t('admin.claims.claimant', { name: claim.displayName })}
                  </span>
                  <span className="font-mono text-[10px] text-fg-dim">
                    {formatDay(claim.createdAt)}
                  </span>
                </span>
                <span className="flex items-center gap-2">
                  <button
                    type="button"
                    disabled={pendingId !== null}
                    onClick={() => void decide(claim, 'approve')}
                    className="min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
                  >
                    {t('admin.claims.approve')}
                  </button>
                  <button
                    type="button"
                    disabled={pendingId !== null}
                    onClick={() => void decide(claim, 'reject')}
                    className="min-h-11 rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
                  >
                    {t('admin.claims.reject')}
                  </button>
                </span>
              </div>
            </li>
          ))}
        </ul>
      )}
      {failure !== null && (
        <ErrorText className="mt-2">{failure}</ErrorText>
      )}
    </section>
  )
}
