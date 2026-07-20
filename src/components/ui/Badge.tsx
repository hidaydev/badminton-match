import type { ReactNode, HTMLAttributes } from 'react'

type BadgeVariant = 'success' | 'warning' | 'error' | 'info' | 'neutral'

interface BadgeProps extends HTMLAttributes<HTMLSpanElement> {
  variant?: BadgeVariant
  children: ReactNode
}

const variantStyles: Record<BadgeVariant, string> = {
  success: 'text-emerald-400 bg-emerald-900/30 border-emerald-800',
  warning: 'text-amber-400 bg-amber-900/30 border-amber-800',
  error: 'text-red-400 bg-red-900/30 border-red-800',
  info: 'text-sky-400 bg-sky-900/30 border-sky-800',
  neutral: 'text-slate-400 bg-slate-800/50 border-slate-700',
}

export default function Badge({ variant = 'neutral', children, className = '', ...props }: BadgeProps) {
  return (
    <span
      className={`inline-flex items-center text-[10px] px-1.5 py-0.5 rounded border font-medium ${variantStyles[variant]} ${className}`}
      {...props}
    >
      {children}
    </span>
  )
}
