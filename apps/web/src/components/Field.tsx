import type { ComponentProps, ReactNode } from 'react'

/**
 * One box for every text input and select on the V2 screens, taken from the
 * search box on the players list. The control is the label's child, which is
 * what names it; there is no id/htmlFor plumbing.
 */
const CONTROL =
  'mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-visible:ring-2 focus-visible:ring-accent'

function join(...parts: (string | undefined)[]): string {
  return parts.filter((part) => part !== undefined && part !== '').join(' ')
}

type FieldProps = {
  label: ReactNode
  hint?: ReactNode
  children: ReactNode
  /** Placement only, for a label that has to grow in a flex or grid row. */
  className?: string
}

export function Field({ label, hint, children, className }: FieldProps) {
  return (
    <label className={join('block text-xs text-fg-dim', className)}>
      {label}
      {children}
      {hint !== undefined && <p className="mt-1 text-xs text-fg-dim">{hint}</p>}
    </label>
  )
}

export function Input({ className, ...props }: ComponentProps<'input'>) {
  return <input {...props} className={join(CONTROL, className)} />
}

export function Select({ className, ...props }: ComponentProps<'select'>) {
  return <select {...props} className={join(CONTROL, className)} />
}