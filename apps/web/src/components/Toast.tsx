import type { ReactNode } from 'react'
import { t } from '../i18n'

export type ToastProps = {
  /** The sentence the user reads. */
  message: ReactNode
  /** Retries the failed action in place. */
  onRetry?: () => void
  /**
   * An action that is not a plain retry, e.g. "Load the server's version" when
   * resending cannot succeed. It sits between retry and dismiss.
   */
  action?: ReactNode
  /**
   * Clears the toast. Without it the toast stays until the caller clears it,
   * which is deliberate: a failure is not an acknowledgement, so nothing here
   * starts a timer.
   */
  onDismiss?: () => void
}

/**
 * The one toast surface (DS-24). It floats above every overlay, carries
 * `role="alert"` itself so no call site retypes the live region, and offers at
 * most three actions in a fixed order: retry, a caller-supplied action, close.
 *
 * One toast per screen at a time. Two failures at once are a screen that should
 * show one of them inline, not a stack of floating boxes.
 */
export function Toast({ message, onRetry, action, onDismiss }: ToastProps) {
  return (
    <div
      role="alert"
      data-testid="toast"
      className="fixed top-4 left-1/2 -translate-x-1/2 z-toast flex w-full max-w-panel items-center gap-3 rounded-lg border border-red-700 bg-red-900/90 px-4 py-2 text-xs text-red-200"
    >
      <span className="min-w-0 flex-1">{message}</span>
      {onRetry && (
        <button
          type="button"
          onClick={onRetry}
          className="min-h-11 shrink-0 rounded-lg border border-red-500 px-2 font-bold text-red-100 transition-colors hover:bg-red-800"
        >
          {t('session.action.retry')}
        </button>
      )}
      {action}
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
