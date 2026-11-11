import type { ComponentProps } from 'react'

/**
 * The one checkbox in the product. `accent-accent` tints the native tick with
 * the brand gold; the previous `text-accent`/`bg-elevated` styling was a no-op
 * on a native input.
 */
const STYLE =
  'h-5 w-5 shrink-0 accent-accent focus-ring disabled:cursor-not-allowed disabled-dim-soft'

export function Checkbox({ className, ...props }: ComponentProps<'input'>) {
  return (
    <input
      {...props}
      type="checkbox"
      className={className === undefined ? STYLE : `${STYLE} ${className}`}
    />
  )
}
