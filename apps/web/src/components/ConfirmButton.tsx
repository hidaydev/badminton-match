import { useState } from 'react'
import type { ReactNode } from 'react'
import { Button } from './Button'

type ConfirmButtonProps = {
  children: ReactNode
  /** Shown once the first click has armed the action. */
  confirmLabel: ReactNode
  onConfirm: () => void
  disabled?: boolean
  variant?: 'primary' | 'secondary' | 'danger'
  className?: string
}

/**
 * A destructive action with an inline armed state. The first click changes the
 * label, the second runs; leaving the button disarms it. This replaces the
 * browser dialog, which ignored the design system and could not be styled or
 * screenshotted.
 */
export function ConfirmButton({
  children,
  confirmLabel,
  onConfirm,
  disabled,
  variant = 'danger',
  className,
}: ConfirmButtonProps) {
  const [armed, setArmed] = useState(false)

  return (
    <Button
      variant={variant}
      className={className}
      disabled={disabled}
      aria-live="polite"
      onBlur={() => setArmed(false)}
      onClick={() => {
        if (!armed) {
          setArmed(true)
          return
        }
        setArmed(false)
        onConfirm()
      }}
    >
      {armed ? confirmLabel : children}
    </Button>
  )
}
