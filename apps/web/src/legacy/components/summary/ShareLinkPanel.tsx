import { useEffect, useRef, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { t } from '@/i18n'
import {
  deleteSessionShareLink,
  ensureSessionShareLink,
  getSessionShareCode,
  rotateSessionShareLink,
} from '../../queries/endpoints'
import { communityQueryKey } from '../../queries/keys'
import { Overlay } from '@/components/Overlay'

/**
 * Host/admin control for the public link of one session. The panel is the shared
 * bottom sheet, so its trigger keeps the toolbar slot it always had; every action
 * is a real button, and a revoked link disappears as soon as the mutation settles.
 */
export default function ShareLinkPanel({ sessionId }: { sessionId: string }) {
  const queryClient = useQueryClient()
  const [open, setOpen] = useState(false)
  const [confirmRevoke, setConfirmRevoke] = useState(false)
  const [copied, setCopied] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const confirmRef = useRef<HTMLButtonElement>(null)
  const revokeRef = useRef<HTMLButtonElement>(null)
  const returnToRevoke = useRef(false)

  // The Revoke button is replaced by the confirm pair; keep focus on it, and
  // hand focus back when Cancel unmounts the pressed button instead of letting
  // it fall to <body> outside the trap.
  useEffect(() => {
    if (confirmRevoke) {
      confirmRef.current?.focus()
      return
    }
    if (returnToRevoke.current) {
      returnToRevoke.current = false
      revokeRef.current?.focus()
    }
  }, [confirmRevoke])

  function cancelRevoke() {
    returnToRevoke.current = true
    setConfirmRevoke(false)
  }

  const shareKey = communityQueryKey('session-share', sessionId)
  const { data: code = null, isLoading } = useQuery({
    queryKey: shareKey,
    queryFn: () => getSessionShareCode(sessionId),
  })

  const create = useMutation({
    mutationFn: () => ensureSessionShareLink(sessionId),
    onSuccess: (next) => {
      setError(null)
      queryClient.setQueryData(shareKey, next)
      // The click that created the link is the gesture the clipboard needs, so
      // copying here is a best effort: a blocked write leaves the Copy button.
      void navigator.clipboard
        .writeText(shareUrl(next))
        .then(() => setCopied(true))
        .catch(() => {})
    },
    onError: () => setError(t('session.share.error')),
  })

  const rotate = useMutation({
    mutationFn: () => rotateSessionShareLink(sessionId),
    onSuccess: (next) => {
      setError(null)
      setCopied(false)
      queryClient.setQueryData(shareKey, next)
    },
    onError: () => setError(t('session.share.error')),
  })

  const revoke = useMutation({
    mutationFn: () => deleteSessionShareLink(sessionId),
    onSuccess: async () => {
      setConfirmRevoke(false)
      setCopied(false)
      setError(null)
      queryClient.setQueryData(shareKey, null)
      await queryClient.invalidateQueries({ queryKey: shareKey })
    },
    onError: () => {
      setConfirmRevoke(false)
      setError(t('session.share.error'))
    },
  })

  const shareUrl = (value: string) => `${window.location.origin}/s/${value}`
  const url = code === null ? null : shareUrl(code)
  const busy = create.isPending || rotate.isPending || revoke.isPending

  function close() {
    setOpen(false)
    setConfirmRevoke(false)
  }

  async function handleCopy() {
    if (url === null) return
    try {
      await navigator.clipboard.writeText(url)
      setCopied(true)
      setError(null)
    } catch {
      setError(t('session.share.error'))
    }
  }

  return (
    <div className="relative">
      <button
        type="button"
        onClick={() => setOpen(true)}
        aria-expanded={open}
        aria-haspopup="dialog"
        className="text-xs font-semibold px-3 py-1.5 rounded-lg bg-slate-800/60 border border-slate-700 text-slate-300 hover:text-white transition-colors hit44"
      >
        {t('session.share')}
      </button>
      {open && (
        <Overlay onClose={close} title={t('session.share')}>
          <div className="flex flex-col gap-2">
            {isLoading ? (
              <span className="text-xs text-slate-400">{t('common.loading')}</span>
            ) : url === null ? (
              <div className="flex flex-wrap items-center gap-2">
                <span className="text-xs text-slate-400">{t('session.share.none')}</span>
                <button
                  type="button"
                  onClick={() => create.mutate()}
                  disabled={busy}
                  className="text-xs font-semibold px-2.5 py-1 rounded-lg bg-indigo-400 hover:bg-indigo-300 disabled:opacity-50 text-slate-950 transition-colors hit44"
                >
                  {create.isPending ? t('session.share.working') : t('session.share.create')}
                </button>
              </div>
            ) : (
              <>
                <code className="block break-all rounded-lg border border-slate-800 bg-slate-950/60 px-2 py-1.5 text-[11px] text-slate-300">{url}</code>
                <div className="flex flex-wrap items-center gap-2">
                  <button
                    type="button"
                    onClick={handleCopy}
                    className={`hit44 text-xs font-semibold px-2.5 py-1 rounded-lg transition-colors ${copied ? 'bg-emerald-400 text-slate-950' : 'bg-indigo-400 hover:bg-indigo-300 text-slate-950'}`}
                  >
                    {copied ? t('session.share.copied') : t('session.share.copy')}
                  </button>
                  <a
                    href={url}
                    target="_blank"
                    rel="noreferrer"
                    className="text-xs font-semibold px-2.5 py-1 rounded-lg bg-slate-800 border border-slate-600 text-slate-200 hover:text-white transition-colors"
                  >
                    {t('session.share.open')}
                  </a>
                  <button
                    type="button"
                    onClick={() => rotate.mutate()}
                    disabled={busy}
                    className="text-xs font-semibold px-2.5 py-1 rounded-lg bg-amber-900/40 border border-amber-700 text-amber-200 hover:text-white disabled:opacity-50 transition-colors hit44"
                  >
                    {rotate.isPending ? t('session.share.working') : t('session.share.rotate')}
                  </button>
                  {!confirmRevoke ? (
                    <button
                      ref={revokeRef}
                      type="button"
                      onClick={() => { setConfirmRevoke(true); setError(null) }}
                      disabled={busy}
                      className="text-xs font-semibold px-2.5 py-1 rounded-lg bg-red-900/30 border border-red-800 text-red-300 hover:text-white disabled:opacity-50 transition-colors hit44"
                    >
                      {t('session.share.revoke')}
                    </button>
                  ) : (
                    <>
                      <span className="text-[11px] text-red-300">{t('session.share.revokeConfirm')}</span>
                      <button
                        ref={confirmRef}
                        type="button"
                        onClick={() => revoke.mutate()}
                        disabled={busy}
                        className="text-xs font-bold px-2.5 py-1 rounded-lg bg-red-600 hover:bg-red-500 text-white disabled:opacity-50 transition-colors hit44"
                      >
                        {revoke.isPending ? t('session.share.working') : t('session.share.revokeYes')}
                      </button>
                      <button
                        type="button"
                        onClick={cancelRevoke}
                        disabled={busy}
                        className="text-xs font-semibold px-2.5 py-1 rounded-lg bg-slate-800 border border-slate-600 text-slate-300 hover:text-white disabled:opacity-50 transition-colors hit44"
                      >
                        {t('session.share.cancel')}
                      </button>
                    </>
                  )}
                </div>
              </>
            )}
            {error && (
              <span role="alert" className="text-[11px] text-red-300">{error}</span>
            )}
            <span role="status" className="sr-only">{copied ? t('session.share.copied') : ''}</span>
          </div>
        </Overlay>
      )}
    </div>
  )
}