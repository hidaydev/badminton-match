import type { ComponentProps, ElementType, ReactNode } from 'react'

/** The container recipe. Only this file may spell it out. */
export const CARD_RECIPE = 'border border-border-subtle bg-surface'

const PADDING = {
  none: '',
  sm: 'p-3',
  md: 'p-4',
  lg: 'p-6',
} as const

export type CardPadding = keyof typeof PADDING

/** Adoption keeps the corner a site already had (docs/design/panel-mapping.md §2). */
const RADIUS = {
  '2xl': 'rounded-2xl',
  xl: 'rounded-xl',
  lg: 'rounded-lg',
} as const

export type CardRadius = keyof typeof RADIUS

/**
 * `interactive` is for the whole-surface target (docs/design/cta-recipe.md §3):
 * the card itself is the control, so it is rendered as the caller's `as`
 * element rather than wrapped in a button.
 */
const INTERACTIVE =
  'w-full text-left transition-[border-color,transform] duration-150 hover:border-border active:scale-[0.99] focus-ring cursor-pointer'

type CardProps = ComponentProps<'div'> & {
  padding?: CardPadding
  radius?: CardRadius
  /** `flush` is for children that draw their own dividers: a list or a table. */
  variant?: 'panel' | 'flush' | 'interactive'
  /** The element to render. Pass `'button'` for an interactive card. */
  as?: ElementType
  /** Only used when `as="button"`: keeps the card from submitting a form. */
  type?: 'button' | 'submit' | 'reset'
  /** Only used when `as="a"` or with a router link element. */
  href?: string
  children: ReactNode
}

const FLUSH = 'overflow-hidden'

/**
 * The V2 panel. The radius, border and surface are the recipe; the padding is
 * a closed set so a page cannot reintroduce its own copy of the container.
 */
export function Card({
  className,
  padding = 'none',
  radius = '2xl',
  variant = 'panel',
  as,
  type = 'button',
  children,
  ...rest
}: CardProps) {
  const Element = as ?? 'div'
  const classes = [
    CARD_RECIPE,
    RADIUS[radius],
    variant === 'flush' ? FLUSH : undefined,
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
