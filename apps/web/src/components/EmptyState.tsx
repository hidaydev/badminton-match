import type { ElementType, ReactNode } from 'react'

type EmptyStateProps = {
  title: ReactNode
  description?: ReactNode
  /** The call to action. Rendered below the copy. */
  action?: ReactNode
  icon?: ReactNode
  /** Heading level for the title. Defaults to a paragraph. */
  as?: ElementType
  /** Overrides the title type scale, for a block that is the page heading. */
  titleClassName?: string
  className?: string
}

/**
 * The one "there is nothing here yet" block. Eight hand written empties had
 * three shapes and only one of them offered an action.
 */
export function EmptyState({
  title,
  description,
  action,
  icon,
  as,
  titleClassName = '',
  className,
}: EmptyStateProps) {
  const Title = as ?? 'p'
  const titleClasses = ['text-sm font-semibold text-fg', titleClassName].filter(Boolean).join(' ')
  return (
    <div
      className={[
        'flex flex-col items-center justify-center gap-1 rounded-xl px-4 py-8 text-center',
        className,
      ]
        .filter(Boolean)
        .join(' ')}
    >
      {icon !== undefined && <div className="mb-1 text-fg-dim">{icon}</div>}
      <Title className={titleClasses}>{title}</Title>
      {description !== undefined && (
        <p className="mt-1 text-sm text-fg-dim">{description}</p>
      )}
      {action !== undefined && <div className="mt-3">{action}</div>}
    </div>
  )
}
