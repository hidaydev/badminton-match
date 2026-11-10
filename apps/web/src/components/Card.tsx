import type { ComponentProps, ElementType, ReactNode } from 'react'

/** The container recipe. Only this file may spell it out. */
export const CARD_RECIPE = 'rounded-2xl border border-border-subtle bg-surface'

const PADDING = {
  none: '',
  sm: 'p-3',
  md: 'p-4',
} as const

export type CardPadding = keyof typeof PADDING

/**
 * `interactive` is for the whole-surface target (docs/design/cta-recipe.md §3):
 * the card itself is the control, so it is rendered as the caller's `as`
 * element rather than wrapped in a button.
 */
const INTERACTIVE =
  'w-full text-left transition-[border-color,transform] duration-150 hover:border-border active:scale-[0.99] focus-ring cursor-pointer'

type CardProps = ComponentProps<'div'> & {
  padding?: CardPadding
  variant?: 'panel' | 'interactive'
  /** The element to render. Pass `'button'` for an interactive card. */
  as?: ElementType
  /** Only used when `as="button"`: keeps the card from submitting a form. */
  type?: 'button' | 'submit' | 'reset'
  /** Only used when `as="a"` or with a router link element. */
  href?: string
  children: ReactNode
}

/**
 * The V2 panel. The radius, border and surface are the recipe; the padding is
 * a closed set so a page cannot reintroduce its own copy of the container.
 */
export function Card({
  className,
  padding = 'none',
  variant = 'panel',
  as,
  type = 'button',
  children,
  ...rest
}: CardProps) {
  const Element = as ?? 'div'
  const classes = [
    CARD_RECIPE,
    PADDING[padding],
    variant === 'interactive' ? INTERACTIVE : undefined,
    className,
  ]
    .filter((part) => part !== undefined && part !== '')
    .join(' ')

  if (as === 'button') {
    return (
      <Element {...rest} type={type} className={classes}>
        {children}
      </Element>
    )
  }

  return (
    <Element className={classes} {...rest}>
      {children}
    </Element>
  )
}
