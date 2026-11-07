import type { ReactNode } from 'react'

/**
 * The V2 panel. The radius, border and surface are the recipe; padding stays
 * with the caller because panels use p-3, p-4 and p-6.
 */
export function Card({ className, children }: { className?: string; children: ReactNode }) {
  return (
    <div className={`rounded-2xl border border-border-subtle bg-surface ${className ?? ''}`}>
      {children}
    </div>
  )
}