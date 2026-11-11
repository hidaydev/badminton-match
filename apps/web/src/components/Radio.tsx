import type { ComponentProps } from 'react'

/** The one radio in the product, tinted with the brand gold via `accent-color`. */
const STYLE =
  'h-5 w-5 shrink-0 accent-accent focus-ring disabled:cursor-not-allowed disabled-dim-soft'

export function Radio({ className, ...props }: ComponentProps<'input'>) {
  return (
    <input
      {...props}
      type="radio"
      className={className === undefined ? STYLE : `${STYLE} ${className}`}
    />
  )
}
