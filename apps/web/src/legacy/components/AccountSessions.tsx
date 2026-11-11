import { useCallback, useEffect, useState } from 'react'
import { listAuthSessions, revokeOtherAuthSessions } from '../../auth/api'
import type { AuthSession } from '../../auth/api'
import { Overlay } from '../../components/Overlay'
import { ErrorText } from '../../components/ErrorText'
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
    <Overlay
      onClose={onClose}
      title={t('sessions.authTitle')}
      description={t('sessions.hint')}
      footer={
        <div className="flex flex-wrap items-center gap-2">
          {hasOthers && (
            confirm ? (
              <>
                <span className="text-sm text-fg">{t('sessions.confirm')}</span>
                <button
                  type="button"
                  disabled={busy}
                  onClick={() => { void revoke() }}
                  className="min-h-11 rounded-xl border border-error px-3 text-sm font-semibold text-error hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled-dim"
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
              </>
            ) : (
              <button
                type="button"
                disabled={busy}
                onClick={() => setConfirm(true)}
                className="min-h-11 rounded-xl border border-border px-3 text-sm text-fg hover:bg-elevated focus-visible:ring-2 focus-visible:ring-accent disabled-dim"
              >
                {t('sessions.signOutOthers')}
              </button>
            )
          )}
          <button
            type="button"
            onClick={onClose}
            className="ml-auto min-h-11 rounded-xl px-3 text-sm text-fg-dim hover:bg-elevated hover:text-fg focus-visible:ring-2 focus-visible:ring-accent"
          >
            {t('sessions.close')}
          </button>
        </div>
      }
    >
      {sessions === null && failure === null && (
        <p role="status" className="text-sm text-fg-dim">
          {t('common.loading')}
        </p>
      )}
      {failure !== null && <ErrorText>{failure}</ErrorText>}
      {sessions !== null && (
        <ul className="space-y-2">
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
    </Overlay>
  )
}