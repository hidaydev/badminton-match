import { useState } from 'react'
import {
  deleteTournament,
  finalizeSource,
  ingestTournamentRating,
  revertTournamentRating,
} from '../api'
import { t } from '../../i18n'
import type { MessageKey } from '../../i18n'

type Props = {
  slug: string
  id: string
  /** Called after a successful delete so the page can leave the editor. */
  onDeleted: () => void
}

type Message = { key: MessageKey; vars?: Record<string, string | number> }

/**
 * Admin-only actions. The route already keeps members and hosts out, but the
 * rating endpoints are admin-gated on the server, so the page renders this
 * block only for an `admin` membership.
 */
export function AdminTools({ slug, id, onDeleted }: Props) {
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<Message | null>(null)
  const [error, setError] = useState<MessageKey | null>(null)
  const [confirming, setConfirming] = useState(false)
  const [confirmed, setConfirmed] = useState(false)

  const run = async (
    action: () => Promise<void>,
    next: Message | null = null,
  ) => {
    setBusy(true)
    setError(null)
    setMessage(null)
    try {
      await action()
      setMessage(next)
    } catch {
      setError('error.load')
    } finally {
      setBusy(false)
    }
  }

  const remove = async () => {
    setBusy(true)
    setError(null)
    try {
      await deleteTournament(slug, id)
      onDeleted()
    } catch {
      setError('error.load')
      setBusy(false)
    }
  }

  return (
    <section className="mt-8 rounded-2xl border border-border-subtle bg-surface p-4">
      <h2 className="text-sm font-semibold text-fg">{t('nav.group.admin')}</h2>

      <div className="mt-3 flex flex-wrap gap-2">
        <button
          type="button"
          disabled={busy}
          onClick={() =>
            void run(
              () => finalizeSource(slug, id, true),
              { key: 'team.rating.finalized' },
            )
          }
          className="min-h-11 rounded-xl border border-border bg-elevated px-4 text-sm text-fg hover:bg-surface focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40"
        >
          {t('team.rating.finalize')}
        </button>

        <button
          type="button"
          disabled={busy}
          onClick={() =>
            void run(async () => {
              const result = await ingestTournamentRating(slug, id)
              setMessage({
                key: 'team.rating.done',
                vars: { events: result.events, deltas: result.deltas },
              })
            })
          }
          className="min-h-11 rounded-xl border border-border bg-elevated px-4 text-sm text-fg hover:bg-surface focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40"
        >
          {t('team.rating.ingest')}
        </button>

        <button
          type="button"
          disabled={busy}
          onClick={() =>
            void run(() => revertTournamentRating(slug, id), {
              key: 'tournament.saved',
            })
          }
          className="min-h-11 rounded-xl border border-border bg-elevated px-4 text-sm text-fg hover:bg-surface focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40"
        >
          {t('team.rating.revert')}
        </button>
      </div>

      {message !== null && (
        <p role="status" className="mt-3 text-sm text-fg-dim">
          {t(message.key, message.vars)}
        </p>
      )}
      {error !== null && (
        <p role="alert" className="mt-3 text-sm text-error">
          {t(error)}
        </p>
      )}

      <div className="mt-6 border-t border-border-subtle pt-4">
        {!confirming ? (
          <button
            type="button"
            disabled={busy}
            onClick={() => setConfirming(true)}
            className="min-h-11 rounded-xl border border-border px-4 text-sm text-error hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40"
          >
            {t('tournaments.delete')}
          </button>
        ) : (
          <div
            role="group"
            aria-label={t('tournaments.deleteConfirm')}
            className="grid gap-2"
          >
            <p className="text-sm text-fg-dim">{t('tournaments.deleteConfirm')}</p>
            <label className="flex min-h-11 items-center gap-2 text-sm text-fg">
              <input
                type="checkbox"
                checked={confirmed}
                onChange={(event) => setConfirmed(event.target.checked)}
                className="h-4 w-4 rounded border-border bg-elevated text-accent focus-visible:ring-2 focus-visible:ring-accent"
              />
              {t('tournaments.deleteConfirm')}
            </label>
            <button
              type="button"
              disabled={busy || !confirmed}
              onClick={() => void remove()}
              className="min-h-11 justify-self-start rounded-xl border border-border px-4 text-sm text-error hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-40"
            >
              {t('tournaments.delete')}
            </button>
          </div>
        )}
      </div>
    </section>
  )
}
