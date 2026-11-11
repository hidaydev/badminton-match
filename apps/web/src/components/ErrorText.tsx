import type { ReactNode } from 'react'

/**
 * `role="alert"` already carries an implicit assertive `aria-live`; adding one
 * on top makes the announcement contradict itself on some screen readers; the
 * older error banner made the same mistake.
 *
 * The live region lives here so no call site retypes it (DS-24). `inherit` is
 * for a message that already sits inside a panel and must keep its own size and
 * colour: the announcement stays here, the look comes from the caller.
 */
export function ErrorText({
  children,
  className,
  id,
  as: Tag = 'p',
  inherit = false,
}: {
  children: ReactNode
  /** Placement only, e.g. the top margin that separates it from the form. */
  className?: string
  /** Set when a field points at this text from `aria-describedby`. */
  id?: string
  /** `span` and `div` are for a message that already sits in a panel or a flex row. */
  as?: 'p' | 'span' | 'div'
  /** The caller owns size and colour; only the live region comes from here. */
  inherit?: boolean
}) {
  const base = inherit ? '' : 'text-sm text-error'
  const classes = base === '' ? className : className === undefined ? base : `${base} ${className}`
  return (
    <Tag id={id} role="alert" className={classes}>
      {children}
    </Tag>
  )
}
