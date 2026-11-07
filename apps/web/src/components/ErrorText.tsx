import type { ReactNode } from 'react'

/**
 * `role="alert"` already carries an implicit assertive `aria-live`; adding one
 * on top makes the announcement contradict itself on some screen readers (see
 * `legacy/components/ErrorBanner.tsx`).
 */
export function ErrorText({
  children,
  className,
}: {
  children: ReactNode
  /** Placement only, e.g. the top margin that separates it from the form. */
  className?: string
}) {
  return (
    <p
      role="alert"
      className={className === undefined ? 'text-sm text-error' : `text-sm text-error ${className}`}
    >
      {children}
    </p>
  )
}