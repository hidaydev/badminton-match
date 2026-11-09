import { t } from '../../i18n'

/**
 * Toast error yang dipakai di beberapa halaman. `role="alert"` sudah membawa
 * `aria-live="assertive"` implisit; menambahkan aria-live lain membuat
 * pembacaan kontradiktif di beberapa screen reader.
 *
 * A failure is not a success acknowledgement: it stays on screen until the
 * caller dismisses it or retries the action.
 */
export default function ErrorBanner({
  message,
  onRetry,
  onDismiss,
}: {
  message: string
  onRetry?: () => void
  onDismiss?: () => void
}) {
  return (
    <div className="fixed top-4 left-1/2 -translate-x-1/2 z-60 flex w-full max-w-xl items-center gap-3 bg-red-900/90 border border-red-700 text-red-200 text-xs px-4 py-2 rounded-lg" role="alert">
      <span className="min-w-0">{message}</span>
      {onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="min-h-11 shrink-0 rounded-lg border border-red-500 px-2 font-bold text-red-100 transition-colors hover:bg-red-800"
        >
          {t('session.action.retry')}
        </button>
      )}
      {onDismiss && (
        <button
          type="button"
          onClick={onDismiss}
          className="min-h-11 shrink-0 rounded-lg px-2 text-red-300 underline underline-offset-2 transition-colors hover:text-red-100"
        >
          {t('session.action.dismiss')}
        </button>
      )}
    </div>
  )
}