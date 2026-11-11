import { cloneElement, isValidElement, useId } from 'react'
import type { ComponentProps, ReactElement, ReactNode } from 'react'
import { ErrorText } from './ErrorText'

/**
 * One named control with an optional hint and error. The id is generated unless
 * the caller passes one, and the hint and error ids are wired to the control
 * through `aria-describedby`, so both are part of its accessible description.
 * An error also marks the control `aria-invalid`, which is what turns on the
 * invalid border and ring already declared on the shared control class.
 */
const CONTROL =
  'mt-1 min-h-11 w-full rounded-xl border border-border bg-elevated px-3 text-sm text-fg focus-ring disabled:cursor-not-allowed disabled-dim-soft read-only:opacity-60 aria-invalid:border-error aria-invalid:ring-1 aria-invalid:ring-error'

function join(...parts: (string | undefined)[]): string {
  return parts.filter((part) => part !== undefined && part !== '').join(' ')
}

type FieldProps = {
  label: ReactNode
  hint?: ReactNode
  /** Validation message; marks the control invalid and describes it. */
  error?: ReactNode
  /** Id to use for the control; generated when omitted. */
  id?: string
  children: ReactNode
  /** Placement only, for a label that has to grow in a flex or grid row. */
  className?: string
}

type ControlProps = { id?: string; 'aria-describedby'?: string; 'aria-invalid'?: boolean }

export function Field({ label, hint, error, id, children, className }: FieldProps) {
  const generatedId = useId()
  const inheritedId = isValidElement(children) ? (children.props as ControlProps).id : undefined
  const controlId = id ?? inheritedId ?? generatedId
  const hintId = hint !== undefined ? `${controlId}-hint` : undefined
  const errorId = error !== undefined ? `${controlId}-error` : undefined

  let control = children
  if (isValidElement(children)) {
    const current = children.props as ControlProps
    const describedBy = join(current['aria-describedby'], hintId, errorId) || undefined
    control = cloneElement(children as ReactElement<ControlProps>, {
      id: controlId,
      'aria-describedby': describedBy,
      'aria-invalid': error !== undefined ? true : current['aria-invalid'],
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
      {error !== undefined && (
        <ErrorText className="mt-1" id={errorId}>
          {error}
        </ErrorText>
      )}
    </div>
  )
}

export function Input({ className, ...props }: ComponentProps<'input'>) {
  return <input {...props} className={join(CONTROL, className)} />
}

/**
 * WebKit sizes a native select from its own appearance and ignores `min-height`,
 * so the shared control class alone left it 22px tall and below the 44px touch
 * minimum. An explicit height is honoured by every engine.
 */
export function Select({ className, ...props }: ComponentProps<'select'>) {
  return <select {...props} className={join(CONTROL, 'h-11', className)} />
}
