type Props = {
  /** Read to screen readers; the rows below are decorative. */
  label: string
  rows?: number
}

/**
 * Placeholder rows for a screen whose data has not arrived yet. The rows reuse
 * the surface/border tokens and the same pulse the rankings table already uses,
 * so a slow read looks like the page is filling in instead of one grey line.
 */
export function LoadingState({ label, rows = 3 }: Props) {
  return (
    <div role="status" className="mt-4">
      <span className="sr-only">{label}</span>
      <div aria-hidden="true" className="animate-pulse space-y-2">
        {Array.from({ length: rows }, (_, index) => (
          <div
            key={index}
            className="h-11 rounded-xl border border-border-subtle bg-surface"
          />
        ))}
      </div>
    </div>
  )
}