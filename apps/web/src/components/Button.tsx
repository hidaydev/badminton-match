import type { ComponentPropsWithoutRef } from 'react'
import { Link } from 'react-router-dom'

/**
 * The shipped V2 button, derived from the call sites rather than from the
 * design doc: every button is `min-h-11 rounded-xl`, the primary one is the only
 * one that is `font-semibold`, and none of them use flex centring.
 */
type Variant = 'primary' | 'secondary' | 'danger'
type Size = 'md' | 'sm'

const BASE =
  'min-h-11 rounded-xl transition-[filter,transform] duration-150 active:scale-[0.99] focus-visible:ring-2 focus-visible:ring-accent disabled:cursor-not-allowed disabled:opacity-50 disabled:active:scale-100'

const VARIANT = {
  primary: 'bg-accent font-semibold text-ground hover:brightness-105',
  secondary: 'border border-border text-fg hover:bg-elevated',
  danger: 'border border-border text-error hover:bg-elevated',
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
      {loading && (
        <span
          aria-hidden="true"
          className="mr-2 inline-block h-3.5 w-3.5 animate-spin rounded-full border-2 border-current border-t-transparent align-[-0.125em]"
        />
      )}
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