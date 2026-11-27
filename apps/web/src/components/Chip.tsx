import type { ComponentPropsWithoutRef } from 'react'
import { Spinner } from './Spinner'

/**
 * The filter or single-choice pill (docs/design/cta-recipe.md §3). One look, two
 * densities: the difference between an off and an on chip is `aria-pressed`,
 * not a colour pair the caller picks, so a screen reader hears the state too.
 */
type Size = 'md' | 'sm'
type Variant = 'outline' | 'pill'

const BASE =
  'inline-flex min-h-11 items-center justify-center gap-1.5 transition-[color,background-color,transform] duration-150 hover:text-fg active:scale-[0.99] focus-ring disabled:cursor-not-allowed disabled-dim disabled:active:scale-100'

/** `outline` is the default bordered chip; `pill` is the fully rounded filled chip. */
const VARIANT: Record<Variant, string> = {
  outline:
    'rounded-lg border border-border font-semibold text-fg-dim hover:bg-elevated aria-pressed:border-accent aria-pressed:text-accent',
  pill:
    'rounded-full border border-border-subtle bg-surface font-medium text-fg-dim hover:text-fg hover:border-border aria-pressed:border-accent/60 aria-pressed:bg-accent/20 aria-pressed:text-accent aria-pressed:font-semibold',
}

const SIZE = {
  md: 'px-3 text-xs',
  sm: 'px-2.5 text-2xs',
} satisfies Record<Size, string>

function join(...parts: (string | undefined)[]): string {
  return parts.filter((part) => part !== undefined && part !== '').join(' ')
}

type ChipProps = Omit<ComponentPropsWithoutRef<'button'>, 'aria-pressed'> & {
  /** Toggle state, rendered as `aria-pressed` and as the accent border and ink. */
  selected?: boolean
  size?: Size
  variant?: Variant
  /** Keeps the label and blocks a second press while the choice is applied. */
  loading?: boolean
}

export function Chip({
  selected = false,
  size = 'md',
  variant = 'outline',
  type = 'button',
  disabled,
  loading = false,
  className,
  children,
  ...rest
}: ChipProps) {
  return (
    <button
      {...rest}
      type={type}
      aria-pressed={selected}
      disabled={disabled || loading}
      aria-busy={loading ? true : undefined}
      className={join(BASE, VARIANT[variant], SIZE[size], 'hit44', className)}
    >
      {loading && <Spinner size={12} />}
      {children}
    </button>
  )
}
