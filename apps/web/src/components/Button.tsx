import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'

/**
 * The shipped V2 button, derived from the call sites rather than from the
 * design doc: every button is `min-h-11 rounded-xl`, the primary one is the only
 * one that is `font-semibold`, and none of them use flex centring.
 */
type Variant = 'primary' | 'secondary' | 'danger'
type Size = 'md' | 'sm'

const BASE =
  'min-h-11 rounded-xl focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50'

const VARIANT = {
  primary: 'bg-accent font-semibold text-ground',
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

type ButtonProps = {
  variant?: Variant
  size?: Size
  /** Defaults to `button`: a submit button that forgets the attribute reloads the page. */
  type?: 'button' | 'submit'
  disabled?: boolean
  onClick?: () => void
  /** Placement only, appended after the recipe. */
  className?: string
  children: ReactNode
}

export function Button({
  variant = 'primary',
  size = 'md',
  type = 'button',
  disabled,
  onClick,
  className,
  children,
}: ButtonProps) {
  return (
    <button
      type={type}
      disabled={disabled}
      onClick={onClick}
      className={join(BASE, VARIANT[variant], SIZE[size], className)}
    >
      {children}
    </button>
  )
}

type ButtonLinkProps = {
  to: string
  variant?: Variant
  size?: Size
  /** Placement only, appended after the recipe. */
  className?: string
  children: ReactNode
}

export function ButtonLink({
  to,
  variant = 'primary',
  size = 'md',
  className,
  children,
}: ButtonLinkProps) {
  return (
    <Link to={to} className={join(BASE, VARIANT[variant], SIZE[size], className)}>
      {children}
    </Link>
  )
}