import type { ComponentProps, ReactNode } from 'react'
import { CARD_RECIPE } from './Card'

type CollapsiblePanelProps = Omit<ComponentProps<'details'>, 'title'> & {
  title: ReactNode
  /** One line under the summary, before the body. */
  hint?: ReactNode
}

/**
 * The disclosure panel used by every settings and admin screen. The container
 * recipe comes from Card, the summary carries the 44px hit target, and call
 * sites only pass the heading and the body.
 */
export function CollapsiblePanel({ title, hint, className, children, ...rest }: CollapsiblePanelProps) {
  const classes = [CARD_RECIPE, 'p-4', className].filter((part) => part !== undefined && part !== '').join(' ')
  return (
    <details className={classes} {...rest}>
      <summary className="min-h-11 cursor-pointer text-sm font-semibold text-fg">{title}</summary>
      {hint !== undefined && <p className="mt-1 text-xs text-fg-dim">{hint}</p>}
      {children}
    </details>
  )
}
