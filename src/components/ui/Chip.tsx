import type { ReactNode, HTMLAttributes } from 'react'

type ChipVariant = 'default' | 'selected' | 'success' | 'warning' | 'error'

interface ChipProps extends HTMLAttributes<HTMLSpanElement> {
  variant?: ChipVariant
  children: ReactNode
}

const variantStyles: Record<ChipVariant, string> = {
  default: 'bg-slate-700 text-white',
  selected: 'bg-indigo-900/50 border border-indigo-500 text-indigo-200 ring-1 ring-indigo-500/60',
  success: 'bg-emerald-900/50 border border-emerald-500 text-emerald-200',
  warning: 'bg-amber-900/50 border border-amber-500 text-amber-200',
  error: 'bg-red-900/50 border border-red-500 text-red-200',
}

export default function Chip({ variant = 'default', children, className = '', ...props }: ChipProps) {
  return (
    <span
      className={`inline-flex items-center gap-1 rounded-lg px-2 py-1 text-xs font-medium min-w-0 overflow-hidden ${variantStyles[variant]} ${className}`}
      {...props}
    >
      {children}
    </span>
  )
}
