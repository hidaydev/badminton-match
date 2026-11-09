import type { ComponentProps, ReactNode } from 'react'

/** The container recipe. Only this file may spell it out. */
export const CARD_RECIPE = 'rounded-2xl border border-border-subtle bg-surface'

const PADDING = {
  none: '',
  sm: 'p-3',
  md: 'p-4',
} as const

export type CardPadding = keyof typeof PADDING

/**
 * The V2 panel. The radius, border and surface are the recipe; the padding is
 * a closed set so a page cannot reintroduce its own copy of the container.
 */
type CardProps = ComponentProps<'div'> & {
  padding?: CardPadding
  children: ReactNode
}

export function Card({ className, padding = 'none', children, ...rest }: CardProps) {
  const classes = [CARD_RECIPE, PADDING[padding], className]
    .filter((part) => part !== undefined && part !== '')
    .join(' ')
  return (
    <div className={classes} {...rest}>
      {children}
    </div>
  )
}
