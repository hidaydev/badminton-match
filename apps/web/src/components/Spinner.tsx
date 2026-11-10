type Props = {
  /** Pixel box. The glyph scales with it; 12-16px covers every inline use. */
  size?: number
  /** Screen-reader text. Omit it when the surrounding UI already says "saving". */
  label?: string
  className?: string
}

/**
 * The one spinner in the app. It is a ring with a gap so it reads as motion,
 * and it is decorative by default: a label turns it into a `status` region and
 * marks that region busy, which is the only thing assistive tech can act on.
 */
export function Spinner({ size = 16, label, className }: Props) {
  const labelled = label !== undefined
  return (
    <span
      role={labelled ? 'status' : undefined}
      aria-busy={labelled ? true : undefined}
      aria-hidden={labelled ? undefined : true}
      className={['inline-flex shrink-0 items-center', className].filter(Boolean).join(' ')}
    >
      <svg
        width={size}
        height={size}
        viewBox="0 0 24 24"
        fill="none"
        aria-hidden="true"
        className="animate-spin"
      >
        <circle
          className="opacity-25"
          cx="12"
          cy="12"
          r="10"
          stroke="currentColor"
          strokeWidth="4"
        />
        <path
          className="opacity-75"
          fill="currentColor"
          d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"
        />
      </svg>
      {labelled && <span className="sr-only">{label}</span>}
    </span>
  )
}
