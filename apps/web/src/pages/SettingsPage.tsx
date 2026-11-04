import { useCallback, useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { ApiError } from '../auth/api'
import type { CommunityRole } from '../auth/api'
import { useCommunity } from '../community/CommunityContext'
import {
  createInvite,
  decideJoinRequest,
  listJoinRequests,
  listMembers,
  listRatingSources,
  rebuildRatings,
  removeMember,
  removeRatingSource,
  setMemberRole,
  setSourceFinalized,
} from '../community/adminApi'
import type { Invite, JoinRequest, Member, RatingSource } from '../community/adminApi'
import { t } from '../i18n'
import type { MessageKey } from '../i18n/en'
import { formatDay } from '../utils/day'

type Data = {
  slug: string
  members: Member[]
  requests: JoinRequest[]
  sources: RatingSource[]
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
    Promise.all([listMembers(slug), listJoinRequests(slug), listRatingSources(slug)])
      .then(([members, requests, sources]) => {
        if (!active) return
        setFailure(null)
        setData({ slug, members, requests, sources })
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

      {loading && (
        <p role="status" className="mt-4 text-sm text-fg-dim">
          {t('app.loading')}
        </p>
      )}
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
          <RatingSources
            slug={slug}
            sources={current.sources}
            busy={busy}
            onRun={run}
          />
        </>
      )}
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

function RatingSources({
  slug,
  sources,
  busy,
  onRun,
}: {
  slug: string
  sources: RatingSource[]
  busy: boolean
  onRun: Run
}) {
  return (
    <section className="mt-8">
      <h2 className="text-sm font-semibold text-fg">{t('admin.sources')}</h2>
      <p className="mt-1 text-xs text-fg-dim">{t('admin.sources.hint')}</p>
      <button
        type="button"
        disabled={busy}
        onClick={() => void onRun(() => rebuildRatings(slug))}
        className="mt-2 min-h-11 rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
      >
        {t('admin.sources.rebuild')}
      </button>

      {sources.length === 0 ? (
        <p className="mt-3 text-sm text-fg-dim">{t('admin.sources.empty')}</p>
      ) : (
        <div className="mt-3 overflow-x-auto rounded-2xl border border-border-subtle bg-surface">
          <table className="w-full border-collapse text-sm">
            <caption className="sr-only">{t('admin.sources')}</caption>
            <thead>
              <tr className="border-b border-border text-left text-xs text-fg-dim">
                <th scope="col" className="px-3 py-2 font-semibold">
                  {t('admin.sources.type')}
                </th>
                <th scope="col" className="px-3 py-2 font-semibold">
                  {t('admin.sources.date')}
                </th>
                <th scope="col" className="px-3 py-2 text-right font-semibold">
                  {t('admin.sources.deltas')}
                </th>
                <th scope="col" className="px-3 py-2 text-right font-semibold">
                  {t('admin.sources.state')}
                </th>
              </tr>
            </thead>
            <tbody>
              {sources.map((source) => (
                <tr
                  key={source.id}
                  className="border-b border-border-subtle last:border-b-0"
                >
                  <td className="px-3 py-2 text-fg">{source.type}</td>
                  <td className="px-3 py-2 font-mono text-xs text-fg-dim">{source.date}</td>
                  <td className="px-3 py-2 text-right font-mono text-fg-dim">
                    {source.deltas}
                  </td>
                  <td className="px-3 py-2">
                    <div className="flex flex-wrap justify-end gap-2">
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() =>
                          void onRun(() =>
                            setSourceFinalized(slug, source.id, !source.finalized),
                          )
                        }
                        className="min-h-11 rounded-xl border border-border px-3 text-xs text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
                      >
                        {source.finalized
                          ? t('admin.sources.unfinalize')
                          : t('admin.sources.finalize')}
                      </button>
                      <button
                        type="button"
                        disabled={busy}
                        onClick={() => void onRun(() => removeRatingSource(slug, source.id))}
                        className="min-h-11 rounded-xl border border-border px-3 text-xs text-error hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
                      >
                        {t('admin.sources.remove')}
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}
