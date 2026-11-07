import type { ReactNode } from 'react'

/** The title block every V2 page opens with. */
export function PageHeader({ title, subtitle }: { title: ReactNode; subtitle?: ReactNode }) {
  return (
    <>
      <h1 className="text-xl font-bold text-fg sm:text-2xl">{title}</h1>
      {subtitle !== undefined && <p className="mt-1 text-sm text-fg-dim">{subtitle}</p>}
    </>
  )
}