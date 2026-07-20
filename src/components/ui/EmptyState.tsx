import type { ReactNode } from 'react'

interface EmptyStateProps {
  icon: string
  title?: string
  description?: string
  children?: ReactNode
}

export default function EmptyState({ icon, title, description, children }: EmptyStateProps) {
  return (
    <div className="text-center py-12 text-slate-400">
      <div className="text-4xl mb-3">{icon}</div>
      {title && <p className="text-sm font-medium text-slate-400 mb-1">{title}</p>}
      {description && <p className="text-xs">{description}</p>}
      {children}
    </div>
  )
}
