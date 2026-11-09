import { cloneElement, isValidElement, useId } from 'react'
import type { ComponentProps, ReactElement, ReactNode } from 'react'

/**
 * One named control with an optional hint. The id is generated unless the
 * caller passes one, and the hint's id is wired to the control through
 * `aria-describedby`, so a visual hint is also the accessible description.
 */
const CONTROL =
  'mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-ring disabled:cursor-not-allowed disabled:opacity-60 read-only:opacity-60 aria-invalid:border-error aria-invalid:ring-1 aria-invalid:ring-error'

function join(...parts: (string | undefined)[]): string {
  return parts.filter((part) => part !== undefined && part !== '').join(' ')
}

type FieldProps = {
  label: ReactNode
  hint?: ReactNode
  /** Id to use for the control; generated when omitted. */
  id?: string
  children: ReactNode
  /** Placement only, for a label that has to grow in a flex or grid row. */
  className?: string
}

type ControlProps = { id?: string; 'aria-describedby'?: string }

export function Field({ label, hint, id, children, className }: FieldProps) {
  const generatedId = useId()
  const inheritedId = isValidElement(children) ? (children.props as ControlProps).id : undefined
  const controlId = id ?? inheritedId ?? generatedId
  const hintId = hint !== undefined ? `${controlId}-hint` : undefined

  let control = children
  if (isValidElement(children)) {
    const current = children.props as ControlProps
    const describedBy = join(current['aria-describedby'], hintId) || undefined
    control = cloneElement(children as ReactElement<ControlProps>, {
      id: controlId,
      'aria-describedby': describedBy,
    })
  }

  return (
    <div className={join('block text-xs text-fg-dim', className)}>
      <label htmlFor={controlId}>{label}</label>
      {control}
      {hint !== undefined && (
        <p id={hintId} className="mt-1 text-xs text-fg-dim">
          {hint}
        </p>
      )}
    </div>
  )
}

export function Input({ className, ...props }: ComponentProps<'input'>) {
  return <input {...props} className={join(CONTROL, className)} />
}

export function Select({ className, ...props }: ComponentProps<'select'>) {
  return <select {...props} className={join(CONTROL, className)} />
}
