import type { ReactNode } from 'react'

/**
 * `role="alert"` already carries an implicit assertive `aria-live`; adding one
 * on top makes the announcement contradict itself on some screen readers; the
 * older error banner made the same mistake.
 */
export function ErrorText({
  children,
  className,
  id,
}: {
  children: ReactNode
  /** Placement only, e.g. the top margin that separates it from the form. */
  className?: string
  /** Set when a field points at this text from `aria-describedby`. */
  id?: string
}) {
  return (
    <p
      id={id}
      role="alert"
      className={className === undefined ? 'text-sm text-error' : `text-sm text-error ${className}`}
    >
      {children}
    </p>
  )
}