import type { ReactNode } from 'react'

/** The title block every V2 page opens with. */
export function PageHeader({ title, subtitle }: { title: ReactNode; subtitle?: ReactNode }) {
  return (
    <>
      <h1 className="text-lg font-bold text-fg sm:text-xl">{title}</h1>
      {subtitle !== undefined && <p className="mt-1 text-sm text-fg-dim">{subtitle}</p>}
    </>
  )
}