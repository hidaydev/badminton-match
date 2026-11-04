import { useState } from 'react'
import { Link } from 'react-router-dom'
import { ApiError } from '../auth/api'
import { t } from '../i18n'
import type { SessionDetail, SessionGame } from './api'
import {
  createShareLink,
  deleteShareLink,
  getShareLink,
  lockSession,
  putSchedule,
  saveGame,
  setAbsent,
  skipGame,
  unlockSession,
} from './write'
import type { ShareLink } from './write'

type Props = {
  slug: string
  session: SessionDetail
  onChange: () => void
}

function describe(error: unknown): string {
  if (error instanceof ApiError && error.status === 412) return t('session.stale')
  if (error instanceof ApiError && error.status === 403) return t('session.action.forbidden')
  if (error instanceof ApiError && error.status === 400) return t('session.action.invalid')
  return t('session.action.failed')
}

/** Host and admin controls for one session: lock, link, scores, absences. */
export default function SessionAdmin({ slug, session, onChange }: Props) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [share, setShare] = useState<ShareLink | null | undefined>(undefined)
  const [absent, setAbsentIds] = useState<string[]>(
    session.participants.filter((entry) => entry.absent).map((entry) => entry.playerId),
  )

  const run = async (action: () => Promise<unknown>) => {
    setBusy(true)
    setError(null)
    try {
      await action()
      onChange()
    } catch (problem) {
      setError(describe(problem))
    } finally {
      setBusy(false)
    }
  }

  const loadShare = () => {
    getShareLink(slug, session.id)
      .then((link) => setShare(link))
      .catch(() => setShare(null))
  }

  const locked = session.status === 'locked'

  return (
    <section className="mt-6 rounded-2xl border border-border-subtle bg-surface p-4">
      <h2 className="text-sm font-semibold text-fg">{t('session.manage')}</h2>

      {error !== null && (
        <p role="alert" className="mt-2 text-sm text-error">
          {error}
        </p>
      )}

      <div className="mt-3 flex flex-wrap gap-2">
        <button
          type="button"
          disabled={busy}
          onClick={() => void run(() =>
            locked
              ? unlockSession(slug, session.id, session.version)
              : lockSession(slug, session.id, session.version),
          )}
          className="min-h-11 rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
        >
          {t(locked ? 'session.unlock' : 'session.lock')}
        </button>
      </div>

      <h3 className="mt-4 text-xs font-semibold text-fg-dim uppercase">{t('session.share')}</h3>
      {share === undefined && (
        <button
          type="button"
          onClick={loadShare}
          className="mt-2 min-h-11 rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent"
        >
          {t('session.share.show')}
        </button>
      )}
      {share === null && (
        <div className="mt-2 flex flex-wrap items-center gap-2">
          <span className="text-sm text-fg-dim">{t('session.share.none')}</span>
          <button
            type="button"
            disabled={busy}
            onClick={() =>
              void run(async () => {
                const link = await createShareLink(slug, session.id)
                setShare(link)
              })
            }
            className="min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
          >
            {t('session.share.create')}
          </button>
        </div>
      )}
      {share != null && (
        <div className="mt-2 space-y-2">
          <p className="font-mono text-sm break-all text-fg">{share.code}</p>
          <div className="flex flex-wrap gap-2">
            <Link
              to={`/s/${share.code}`}
              className="inline-flex min-h-11 items-center rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent"
            >
              {t('session.share.open')}
            </Link>
            <button
              type="button"
              disabled={busy}
              onClick={() =>
                void run(async () => {
                  const link = await createShareLink(slug, session.id)
                  setShare(link)
                })
              }
              className="min-h-11 rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
            >
              {t('session.share.rotate')}
            </button>
            <button
              type="button"
              disabled={busy}
              onClick={() =>
                void run(async () => {
                  await deleteShareLink(slug, session.id)
                  setShare(null)
                })
              }
              className="min-h-11 rounded-xl border border-border px-4 text-sm text-error hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
            >
              {t('session.share.revoke')}
            </button>
          </div>
        </div>
      )}

      {/* An empty session has nobody to mark, and a lone Save button would be
          a control that cannot change anything. */}
      {session.participants.length > 0 && (
        <>
          <h3 className="mt-4 text-xs font-semibold text-fg-dim uppercase">
            {t('session.absent.title')}
          </h3>
          <p className="mt-1 text-xs text-fg-dim">{t('session.absent.hint')}</p>
          <ul className="mt-2 flex flex-wrap gap-3">
            {session.participants.map((entry) => (
              <li key={entry.playerId}>
                <label className="flex min-h-11 items-center gap-2 text-sm text-fg">
                  <input
                    type="checkbox"
                    checked={absent.includes(entry.playerId)}
                    onChange={(event) =>
                      setAbsentIds((current) =>
                        event.target.checked
                          ? [...current, entry.playerId]
                          : current.filter((id) => id !== entry.playerId),
                      )
                    }
                    className="h-4 w-4 rounded border-border bg-elevated text-accent focus-visible:ring-2 focus-visible:ring-accent"
                  />
                  {entry.name}
                </label>
              </li>
            ))}
          </ul>
          <button
            type="button"
            disabled={busy}
            onClick={() => void run(() => setAbsent(slug, session.id, absent, session.version))}
            className="mt-2 min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
          >
            {t('session.absent.save')}
          </button>
        </>
      )}

      <h3 className="mt-4 text-xs font-semibold text-fg-dim uppercase">{t('session.games')}</h3>
      <ul className="mt-2 space-y-3">
        {session.games.map((game) => (
          <GameRow
            key={`${game.round}-${game.court}-${session.version}`}
            slug={slug}
            sessionId={session.id}
            version={session.version}
            game={game}
            busy={busy}
            onRun={run}
          />
        ))}
      </ul>
      {/* Remounted per version so the default court follows the schedule the
          server just accepted instead of repeating the row it already has. */}
      <AddGame
        key={session.version}
        slug={slug}
        session={session}
        busy={busy}
        onRun={run}
      />
    </section>
  )
}

type GameRowProps = {
  slug: string
  sessionId: string
  version: number
  game: SessionGame
  busy: boolean
  onRun: (action: () => Promise<unknown>) => Promise<void>
}

function GameRow({ slug, sessionId, version, game, busy, onRun }: GameRowProps) {
  const [scoreA, setScoreA] = useState(game.scoreA === null ? '' : String(game.scoreA))
  const [scoreB, setScoreB] = useState(game.scoreB === null ? '' : String(game.scoreB))
  const key = `${game.round}-${game.court}`
  const parsed = (value: string): number | null => (value === '' ? null : Number(value))

  return (
    <li className="rounded-xl border border-border-subtle bg-elevated p-3">
      <p className="font-mono text-xs text-fg-dim">
        {t('session.game.key', { round: game.round + 1, court: game.court + 1 })} · {game.status}
      </p>
      <div className="mt-2 flex flex-wrap items-end gap-2">
        <label className="text-xs text-fg-dim">
          {t('session.column.sideA')}
          <input
            type="number"
            min={0}
            max={99}
            inputMode="numeric"
            value={scoreA}
            onChange={(event) => setScoreA(event.target.value)}
            className="ml-2 min-h-11 w-20 rounded-xl border border-border bg-surface px-2 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
          />
        </label>
        <label className="text-xs text-fg-dim">
          {t('session.column.sideB')}
          <input
            type="number"
            min={0}
            max={99}
            inputMode="numeric"
            value={scoreB}
            onChange={(event) => setScoreB(event.target.value)}
            className="ml-2 min-h-11 w-20 rounded-xl border border-border bg-surface px-2 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
          />
        </label>
        <button
          type="button"
          disabled={busy}
          onClick={() =>
            void onRun(() => saveGame(slug, sessionId, key, { scoreA: parsed(scoreA), scoreB: parsed(scoreB) }, version))
          }
          className="min-h-11 rounded-xl bg-accent px-4 text-sm font-semibold text-ground focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
        >
          {t('session.save')}
        </button>
        <button
          type="button"
          disabled={busy}
          onClick={() => void onRun(() => skipGame(slug, sessionId, key, version))}
          className="min-h-11 rounded-xl border border-border px-4 text-sm text-fg hover:bg-surface focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
        >
          {t('session.skip')}
        </button>
      </div>
    </li>
  )
}

type AddGameProps = {
  slug: string
  session: SessionDetail
  busy: boolean
  onRun: (action: () => Promise<unknown>) => Promise<void>
}

function AddGame({ slug, session, busy, onRun }: AddGameProps) {
  const nextCourt = session.games.reduce((max, game) => Math.max(max, game.court + 1), 0)
  const [round, setRound] = useState('0')
  const [court, setCourt] = useState(String(nextCourt))
  const [sideA, setSideA] = useState<string[]>(['', ''])
  const [sideB, setSideB] = useState<string[]>(['', ''])

  const pick = (
    current: string[],
    index: number,
    value: string,
  ): string[] => current.map((entry, position) => (position === index ? value : entry))

  const add = () => {
    const game: SessionGame = {
      round: Number(round),
      court: Number(court),
      sideA: sideA.filter((id) => id !== ''),
      sideB: sideB.filter((id) => id !== ''),
      scoreA: null,
      scoreB: null,
      status: 'scheduled',
    }
    return putSchedule(slug, session.id, [...session.games, game], session.version)
  }

  const options = session.participants.filter((entry) => !entry.absent)

  return (
    <div className="mt-3 rounded-xl border border-dashed border-border p-3">
      <p className="text-xs font-semibold text-fg-dim uppercase">{t('session.addGame')}</p>
      <div className="mt-2 flex flex-wrap gap-2">
        <label className="text-xs text-fg-dim">
          {t('session.column.round')}
          <input
            type="number"
            min={0}
            value={round}
            onChange={(event) => setRound(event.target.value)}
            className="ml-2 min-h-11 w-16 rounded-xl border border-border bg-elevated px-2 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
          />
        </label>
        <label className="text-xs text-fg-dim">
          {t('session.column.court')}
          <input
            type="number"
            min={0}
            value={court}
            onChange={(event) => setCourt(event.target.value)}
            className="ml-2 min-h-11 w-16 rounded-xl border border-border bg-elevated px-2 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
          />
        </label>
      </div>
      <div className="mt-2 grid gap-2 sm:grid-cols-2">
        {[
          { label: t('session.column.sideA'), value: sideA, set: setSideA },
          { label: t('session.column.sideB'), value: sideB, set: setSideB },
        ].map((side) => (
          <div key={side.label}>
            <p className="text-xs text-fg-dim">{side.label}</p>
            {[0, 1].map((index) => (
              <select
                key={index}
                value={side.value[index]}
                onChange={(event) => side.set(pick(side.value, index, event.target.value))}
                aria-label={`${side.label} ${index + 1}`}
                className="mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-2 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
              >
                <option value="">{t('session.side.empty')}</option>
                {options.map((entry) => (
                  <option key={entry.playerId} value={entry.playerId}>
                    {entry.name}
                  </option>
                ))}
              </select>
            ))}
          </div>
        ))}
      </div>
      <button
        type="button"
        disabled={busy}
        onClick={() => void onRun(add)}
        className="mt-2 min-h-11 rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
      >
        {t('session.add')}
      </button>
    </div>
  )
}
