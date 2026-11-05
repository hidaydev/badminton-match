import { useCallback, useEffect, useRef, useState } from 'react'
import { listAuthSessions, revokeOtherAuthSessions } from '../../auth/api'
import type { AuthSession } from '../../auth/api'
import { t } from '../../i18n'

type Props = {
  onClose: () => void
}

/** Postgres text timestamps contain a space; `Date` wants the ISO `T`. */
function formatWhen(value: string): string {
  const parsed = new Date(value.includes('T') ? value : value.replace(' ', 'T'))
  if (Number.isNaN(parsed.getTime())) return value
  return parsed.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })
}

/**
 * The devices signed in to this account. Revoking only affects the others, so
 * the control cannot lock the person clicking it out of their own screen.
 */
export default function AccountSessions({ onClose }: Props) {
  const [sessions, setSessions] = useState<AuthSession[] | null>(null)
  const [failure, setFailure] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [confirm, setConfirm] = useState(false)
  const dialogRef = useRef<HTMLDivElement>(null)

  const load = useCallback(async () => {
    try {
      const items = await listAuthSessions()
      setFailure(null)
      setSessions(items)
    } catch {
      setFailure(t('sessions.failed'))
    }
  }, [])

  // Mounted only while open, so the list loads once per opening and a reopened
  // dialog never shows a half-finished confirmation.
  useEffect(() => {
    let active = true
    listAuthSessions()
      .then((items) => {
        if (!active) return
        setFailure(null)
        setSessions(items)
      })
      .catch(() => {
        if (active) setFailure(t('sessions.failed'))
      })
    return () => {
      active = false
    }
  }, [])

  // Same focus contract as the summary dialog: move in, keep Tab inside, hand
  // focus back to the menu button on close.
  useEffect(() => {
    const node = dialogRef.current
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null
    node?.focus()

    function handleKey(event: KeyboardEvent) {
      if (event.key === 'Escape') {
        event.preventDefault()
        onClose()
        return
      }
      if (event.key !== 'Tab' || !node) return
      const focusable = node.querySelectorAll<HTMLElement>(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      )
      if (focusable.length === 0) return
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }

    node?.addEventListener('keydown', handleKey)
    return () => {
      node?.removeEventListener('keydown', handleKey)
      if (previous && document.contains(previous)) previous.focus()
    }
  }, [onClose])

  const revoke = async () => {
    setBusy(true)
    setFailure(null)
    try {
      await revokeOtherAuthSessions()
      setConfirm(false)
      await load()
    } catch {
      setFailure(t('sessions.revokeFailed'))
    } finally {
      setBusy(false)
    }
  }

  const hasOthers = sessions?.some((session) => !session.current) === true

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-black/50 p-3 sm:items-center">
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-label={t('sessions.authTitle')}
        tabIndex={-1}
        className="w-full max-w-md rounded-2xl border border-border-subtle bg-surface p-4 shadow-xl pb-[calc(1rem+env(safe-area-inset-bottom))]"
      >
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-base font-bold text-fg">{t('sessions.authTitle')}</h2>
            <p className="mt-1 text-xs text-fg-dim">{t('sessions.hint')}</p>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="min-h-11 rounded-xl px-3 text-sm text-fg-dim hover:bg-elevated hover:text-fg focus-visible:ring-2 focus-visible:ring-accent"
          >
            {t('sessions.close')}
          </button>
        </div>

        {sessions === null && failure === null && (
          <p role="status" className="mt-4 text-sm text-fg-dim">
            {t('common.loading')}
          </p>
        )}
        {failure !== null && (
          <p role="alert" className="mt-4 text-sm text-error">
            {failure}
          </p>
        )}
        {sessions !== null && (
          <ul className="mt-4 space-y-2">
            {sessions.map((session) => (
              <li
                key={session.id}
                className="rounded-xl border border-border-subtle bg-elevated px-3 py-2"
              >
                <p className="text-sm text-fg">
                  {t('sessions.lastSeen')} {formatWhen(session.lastSeenAt)}
                  {session.current && (
                    <span className="ml-2 rounded-full border border-border-subtle px-2 py-0.5 text-[10px] uppercase tracking-wide text-fg-dim">
                      {t('sessions.current')}
                    </span>
                  )}
                </p>
                <p className="text-xs text-fg-dim">
                  {t('sessions.created')} {formatWhen(session.createdAt)}
                </p>
              </li>
            ))}
          </ul>
        )}

        {hasOthers && (
          <div className="mt-4">
            {confirm ? (
              <div className="flex flex-wrap items-center gap-2">
                <span className="text-sm text-fg">{t('sessions.confirm')}</span>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => { void revoke() }}
                  className="min-h-11 rounded-xl border border-error px-3 text-sm font-semibold text-error hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
                >
                  {t('sessions.confirmAction')}
                </button>
                <button
                  type="button"
                  onClick={() => setConfirm(false)}
                  className="min-h-11 rounded-xl border border-border px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent"
                >
                  {t('sessions.cancel')}
                </button>
              </div>
            ) : (
              <button
                type="button"
                disabled={busy}
                onClick={() => setConfirm(true)}
                className="min-h-11 rounded-xl border border-border px-3 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
              >
                {t('sessions.signOutOthers')}
              </button>
            )}
          </div>
        )}
      </div>
    </div>
  )
}