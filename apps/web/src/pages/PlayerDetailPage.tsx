import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { useCommunity } from '../community/CommunityContext'
import { t } from '../i18n'
import { TIERS } from '../players/api'
import {
  claimPlayer,
  decideClaim,
  deletePlayer,
  mergePlayers,
  releaseOwnClaim,
  updatePlayer,
} from '../players/api'
import type { PlayerClaim } from '../players/api'
import { usePlayerDetail, usePlayers } from '../players/hooks'
import { describePlayerError, parseAliases } from '../players/text'
import { formatDay } from '../utils/day'

type Run = (action: () => Promise<unknown>) => Promise<void>

const CLAIM_STATUS_KEY = {
  pending: 'player.claim.status.pending',
  approved: 'player.claim.status.approved',
  rejected: 'player.claim.status.rejected',
  released: 'player.claim.status.released',
} as const

export default function PlayerDetailPage() {
  const { slug = '', playerId = '' } = useParams<{ slug: string; playerId: string }>()
  const { memberships } = useCommunity()
  const { user } = useAuth()
  const role = memberships.find((candidate) => candidate.slug === slug)?.role ?? null
  const isAdmin = role === 'admin'
  const canEdit = role === 'host' || role === 'admin'

  const { player, claims, loading, error, reload } = usePlayerDetail(
    slug === '' ? null : slug,
    playerId === '' ? null : playerId,
  )
  // Merge needs somewhere to merge from; only an admin can ask for the list.
  const candidates = usePlayers(isAdmin ? slug : null, '')

  const [busy, setBusy] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)

  const run: Run = async (action) => {
    setBusy(true)
    setActionError(null)
    try {
      await action()
      reload()
    } catch (problem) {
      setActionError(describePlayerError(problem))
    } finally {
      setBusy(false)
    }
  }

  const mine = claims?.find(
    (claim) =>
      claim.userId === user?.id &&
      (claim.status === 'pending' || claim.status === 'approved'),
  )
  const linkedToMe = player !== null && user !== null && player.userId === user.id

  return (
    <section className="mx-auto max-w-3xl p-4">
      <Link
        to={`/c/${encodeURIComponent(slug)}/players`}
        className="inline-flex min-h-11 items-center rounded-xl text-sm text-fg-dim hover:text-fg focus-visible:ring-2 focus-visible:ring-accent"
      >
        {t('players.back')}
      </Link>

      {loading && (
        <p role="status" className="mt-2 text-sm text-fg-dim">
          {t('app.loading')}
        </p>
      )}
      {error === 'notFound' && (
        <p role="alert" className="mt-2 text-sm text-error">
          {t('playerAdmin.error.notFound')}
        </p>
      )}
      {error === 'failed' && (
        <p role="alert" className="mt-2 text-sm text-error">
          {t('playerAdmin.error.load')}
        </p>
      )}

      {player !== null && (
        <>
          <header className="mt-2">
            <h1 className="text-xl font-bold text-fg sm:text-2xl">{player.name}</h1>
            <p className="mt-1 text-sm text-fg-dim">
              {player.tier ?? t('players.tier.none')} ·{' '}
              {t(player.gender === 'F' ? 'player.gender.female' : 'player.gender.male')} ·{' '}
              {player.userId === null ? t('players.unclaimed') : t('players.claimed')}
            </p>
            {player.aliases !== undefined && player.aliases.length > 0 && (
              <p className="mt-1 text-xs text-fg-dim">
                {t('playerAdmin.aliases')}: {player.aliases.join(', ')}
              </p>
            )}
          </header>

          {actionError !== null && (
            <p role="alert" className="mt-3 text-sm text-error">
              {actionError}
            </p>
          )}

          <div className="mt-4 flex flex-wrap gap-2">
            {player.userId === null && mine === undefined && (
              <button
                type="button"
                disabled={busy}
                onClick={() => void run(() => claimPlayer(slug, player.id))}
                className="min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
              >
                {t('playerAdmin.claim')}
              </button>
            )}
            {mine?.status === 'pending' && (
              <p className="text-sm text-fg-dim">{t('playerAdmin.claim.pending')}</p>
            )}
            {linkedToMe && (
              <button
                type="button"
                disabled={busy}
                onClick={() => void run(() => releaseOwnClaim(slug, player.id))}
                className="min-h-11 rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
              >
                {t('playerAdmin.release')}
              </button>
            )}
          </div>

          {canEdit && (
            <EditPlayer
              key={player.updatedAt}
              slug={slug}
              player={player}
              busy={busy}
              onRun={run}
            />
          )}

          <h2 className="mt-8 text-sm font-semibold text-fg">{t('playerAdmin.claims')}</h2>
          {claims === null || claims.length === 0 ? (
            <p className="mt-2 text-sm text-fg-dim">{t('playerAdmin.claims.empty')}</p>
          ) : (
            <ul className="mt-2 space-y-2">
              {claims.map((claim) => (
                <ClaimRow
                  key={claim.id}
                  slug={slug}
                  playerId={player.id}
                  claim={claim}
                  admin={isAdmin}
                  own={claim.userId === user?.id}
                  busy={busy}
                  onRun={run}
                />
              ))}
            </ul>
          )}

          {isAdmin && (
            <>
              <MergePanel
                slug={slug}
                playerId={player.id}
                playerName={player.name}
                candidates={candidates.items ?? []}
                busy={busy}
                onRun={run}
              />
              <DeletePanel slug={slug} playerId={player.id} busy={busy} />
            </>
          )}
        </>
      )}
    </section>
  )
}

type EditProps = {
  slug: string
  player: { id: string; name: string; gender: 'M' | 'F'; tier: string | null }
  busy: boolean
  onRun: Run
}

function EditPlayer({ slug, player, busy, onRun }: EditProps) {
  const [name, setName] = useState(player.name)
  const [gender, setGender] = useState<'M' | 'F'>(player.gender)
  const [tier, setTier] = useState(player.tier ?? '')
  const [aliases, setAliases] = useState('')
  const [aliasesTouched, setAliasesTouched] = useState(false)

  return (
    <details className="mt-4 rounded-2xl border border-border-subtle bg-surface p-4">
      <summary className="min-h-11 cursor-pointer text-sm font-semibold text-fg">
        {t('playerAdmin.edit')}
      </summary>
      <div className="mt-3 grid gap-3 sm:grid-cols-2">
        <label className="text-xs text-fg-dim">
          {t('players.add.name')}
          <input
            value={name}
            onChange={(event) => setName(event.target.value)}
            maxLength={80}
            className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
          />
        </label>
        <label className="text-xs text-fg-dim">
          {t('players.add.gender')}
          <select
            value={gender}
            onChange={(event) => setGender(event.target.value === 'F' ? 'F' : 'M')}
            className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
          >
            <option value="M">{t('player.gender.male')}</option>
            <option value="F">{t('player.gender.female')}</option>
          </select>
        </label>
        <label className="text-xs text-fg-dim">
          {t('players.add.tier')}
          <select
            value={tier}
            onChange={(event) => setTier(event.target.value)}
            className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
          >
            <option value="">{t('players.tier.none')}</option>
            {TIERS.map((value) => (
              <option key={value} value={value}>
                {value}
              </option>
            ))}
          </select>
        </label>
        <label className="text-xs text-fg-dim">
          {t('players.add.aliases')}
          <input
            value={aliases}
            onChange={(event) => {
              setAliases(event.target.value)
              setAliasesTouched(true)
            }}
            placeholder={t('playerAdmin.aliases.keep')}
            className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
          />
        </label>
      </div>
      <button
        type="button"
        disabled={busy || name.trim() === ''}
        onClick={() =>
          void onRun(() =>
            updatePlayer(slug, player.id, {
              name: name.trim(),
              gender,
              tier: tier === '' ? null : tier,
              // An untouched field keeps the aliases the server already has.
              ...(aliasesTouched ? { aliases: parseAliases(aliases) } : {}),
            }),
          )
        }
        className="mt-3 min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
      >
        {t('playerAdmin.save')}
      </button>
    </details>
  )
}

type ClaimRowProps = {
  slug: string
  playerId: string
  claim: PlayerClaim
  admin: boolean
  own: boolean
  busy: boolean
  onRun: Run
}

function ClaimRow({ slug, playerId, claim, admin, own, busy, onRun }: ClaimRowProps) {
  const [reason, setReason] = useState('')

  return (
    <li className="rounded-xl border border-border-subtle bg-surface p-3">
      <p className="flex flex-wrap items-baseline justify-between gap-2 text-sm text-fg">
        <span className="font-mono text-xs text-fg-dim">{claim.userId}</span>
        <span className="text-xs text-fg-dim">{t(CLAIM_STATUS_KEY[claim.status])}</span>
      </p>
      <p className="mt-1 font-mono text-[10px] text-fg-dim">{formatDay(claim.createdAt)}</p>
      {claim.reason !== '' && <p className="mt-1 text-xs text-fg-dim">{claim.reason}</p>}

      {admin && !own && claim.status === 'pending' && (
        <div className="mt-2 flex flex-wrap gap-2">
          <button
            type="button"
            disabled={busy}
            onClick={() =>
              void onRun(() => decideClaim(slug, playerId, claim.id, { decision: 'approve' }))
            }
            className="min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
          >
            {t('playerAdmin.decide.approve')}
          </button>
          <button
            type="button"
            disabled={busy}
            onClick={() =>
              void onRun(() => decideClaim(slug, playerId, claim.id, { decision: 'reject' }))
            }
            className="min-h-11 rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
          >
            {t('playerAdmin.decide.reject')}
          </button>
        </div>
      )}

      {admin && !own && claim.status === 'approved' && (
        <div className="mt-2 flex flex-wrap items-end gap-2">
          <label className="min-w-0 flex-1 text-xs text-fg-dim">
            {t('playerAdmin.decide.reason')}
            <input
              value={reason}
              onChange={(event) => setReason(event.target.value)}
              className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
            />
          </label>
          <button
            type="button"
            disabled={busy || reason.trim() === ''}
            onClick={() =>
              void onRun(() =>
                decideClaim(slug, playerId, claim.id, {
                  action: 'release',
                  reason: reason.trim(),
                }),
              )
            }
            className="min-h-11 rounded-xl border border-border px-4 text-sm text-error hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
          >
            {t('playerAdmin.decide.release')}
          </button>
        </div>
      )}
    </li>
  )
}

type MergeProps = {
  slug: string
  playerId: string
  playerName: string
  candidates: { id: string; name: string }[]
  busy: boolean
  onRun: Run
}

function MergePanel({ slug, playerId, playerName, candidates, busy, onRun }: MergeProps) {
  const [source, setSource] = useState('')
  const others = candidates.filter((candidate) => candidate.id !== playerId)

  return (
    <details className="mt-8 rounded-2xl border border-border-subtle bg-surface p-4">
      <summary className="min-h-11 cursor-pointer text-sm font-semibold text-fg">
        {t('playerAdmin.merge')}
      </summary>
      <p className="mt-2 text-xs text-fg-dim">{t('playerAdmin.merge.hint')}</p>
      <div className="mt-2 flex flex-wrap items-end gap-2">
        <label className="min-w-0 flex-1 text-xs text-fg-dim">
          {t('playerAdmin.merge.source')}
          <select
            value={source}
            onChange={(event) => setSource(event.target.value)}
            className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
          >
            <option value="">{t('playerAdmin.merge.pick')}</option>
            {others.map((candidate) => (
              <option key={candidate.id} value={candidate.id}>
                {candidate.name}
              </option>
            ))}
          </select>
        </label>
        <button
          type="button"
          disabled={busy || source === ''}
          onClick={() => {
            const sourceName = others.find((candidate) => candidate.id === source)?.name ?? source
            const confirmed = window.confirm(
              t('playerAdmin.merge.confirm', { source: sourceName, target: playerName }),
            )
            if (confirmed) void onRun(() => mergePlayers(slug, playerId, source))
          }}
          className="min-h-11 rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
        >
          {t('playerAdmin.merge.submit')}
        </button>
      </div>
    </details>
  )
}

function DeletePanel({
  slug,
  playerId,
  busy,
}: {
  slug: string
  playerId: string
  busy: boolean
}) {
  const navigate = useNavigate()
  const [armed, setArmed] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (!armed) {
    return (
      <button
        type="button"
        disabled={busy}
        onClick={() => setArmed(true)}
        className="mt-6 min-h-11 rounded-xl border border-border px-4 text-sm text-error hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
      >
        {t('playerAdmin.delete')}
      </button>
    )
  }

  return (
    <div
      role="group"
      aria-label={t('playerAdmin.delete')}
      className="mt-6 rounded-2xl border border-border-subtle bg-surface p-4"
    >
      <p className="text-sm text-fg-dim">{t('playerAdmin.delete.confirm')}</p>
      {error !== null && (
        <p role="alert" className="mt-2 text-sm text-error">
          {error}
        </p>
      )}
      <div className="mt-3 flex flex-wrap gap-2">
        <button
          type="button"
          disabled={busy}
          onClick={() => {
            setError(null)
            deletePlayer(slug, playerId)
              // The page it would reload is gone, so the list is the way back.
              .then(() => navigate(`/c/${encodeURIComponent(slug)}/players`))
              .catch((problem: unknown) => setError(describePlayerError(problem)))
          }}
          className="min-h-11 rounded-xl border border-border px-4 text-sm text-error hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
        >
          {t('playerAdmin.delete.confirmAction')}
        </button>
        <button
          type="button"
          onClick={() => setArmed(false)}
          className="min-h-11 rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent"
        >
          {t('playerAdmin.delete.cancel')}
        </button>
      </div>
    </div>
  )
}
