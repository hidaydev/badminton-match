import type { ComponentPropsWithoutRef } from 'react'
import { Link } from 'react-router-dom'
import { Spinner } from './Spinner'

/**
 * The shipped V2 button, derived from the call sites rather than from the
 * design doc: every button is `min-h-11 rounded-xl`, the primary one is the only
 * one that is `font-semibold`, and none of them use flex centring.
 *
 * `ghost` and `dashed` were added for the call sites the CTA recipe classifies
 * them at (docs/design/cta-recipe.md §3.1); the three original variants keep
 * their class strings unchanged.
 */
type Variant = 'primary' | 'secondary' | 'danger' | 'ghost' | 'dashed'
type Size = 'md' | 'sm'

const BASE =
  'min-h-11 rounded-xl transition-[filter,transform] duration-150 active:scale-[0.99] focus-ring disabled:cursor-not-allowed disabled-dim disabled:active:scale-100'

const VARIANT = {
  primary: 'bg-accent font-semibold text-ground hover:brightness-105',
  secondary: 'border border-border text-fg hover:bg-elevated',
  danger: 'border border-border text-error hover:bg-elevated',
  ghost: 'text-fg-dim hover:text-fg hover:underline underline-offset-2',
  dashed: 'border-2 border-dashed border-border text-fg-dim hover:border-accent hover:text-accent',
} satisfies Record<Variant, string>

const SIZE = {
  md: 'px-4 text-sm',
  sm: 'px-3 text-xs',
} satisfies Record<Size, string>

function join(...parts: (string | undefined)[]): string {
  return parts.filter((part) => part !== undefined && part !== '').join(' ')
}

type ButtonProps = ComponentPropsWithoutRef<'button'> & {
  variant?: Variant
  size?: Size
  /** Renders a spinner, marks the button busy and blocks a second submit. */
  loading?: boolean
}

export function Button({
  variant = 'primary',
  size = 'md',
  type = 'button',
  disabled,
  loading = false,
  className,
  children,
  ...rest
}: ButtonProps) {
  return (
    <button
      {...rest}
      type={type}
      disabled={disabled || loading}
      aria-busy={loading ? true : undefined}
      className={join(BASE, VARIANT[variant], SIZE[size], 'hit44', className)}
    >
      {loading && <Spinner size={14} className="mr-2" />}
      {children}
    </button>
  )
}

type ButtonLinkProps = ComponentPropsWithoutRef<typeof Link> & {
  variant?: Variant
  size?: Size
}

export function ButtonLink({
  variant = 'primary',
  size = 'md',
  className,
  children,
  ...rest
}: ButtonLinkProps) {
  return (
    <Link {...rest} className={join(BASE, VARIANT[variant], SIZE[size], 'hit44', className)}>
      {children}
    </Link>
  )
}

/** Square paddings. Both stay 44px tall; `sm` only narrows the box. */
const ICON_SIZE = {
  md: 'h-11 w-11',
  sm: 'h-11 w-9',
} satisfies Record<Size, string>

type IconButtonProps = Omit<ComponentPropsWithoutRef<'button'>, 'aria-label'> & {
  /**
   * The accessible name. Required: an icon-only control has no text for a
   * screen reader to read, and a tooltip is not a label.
   */
  label: string
  variant?: Variant
  size?: Size
  /** Renders a spinner in place of the icon, marks the button busy and blocks a second press. */
  loading?: boolean
}

/**
 * The icon-only action. Same recipe as `Button`, square box, and the name lives
 * in `aria-label` instead of the children.
 */
export function IconButton({
  label,
  variant = 'ghost',
  size = 'md',
  type = 'button',
  disabled,
  loading = false,
  className,
  children,
  ...rest
}: IconButtonProps) {
  return (
    <button
      {...rest}
      type={type}
      aria-label={label}
      disabled={disabled || loading}
      aria-busy={loading ? true : undefined}
      className={join(
        BASE,
        VARIANT[variant],
        ICON_SIZE[size],
        'hit44',
        'inline-flex shrink-0 items-center justify-center',
        className,
      )}
    >
      {loading ? <Spinner size={14} /> : children}
    </button>
  )
}