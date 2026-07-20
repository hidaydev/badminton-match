import type { ReactNode, HTMLAttributes } from 'react'

type CardVariant = 'surface' | 'elevated' | 'interactive'

interface CardProps extends HTMLAttributes<HTMLDivElement> {
  variant?: CardVariant
  children: ReactNode
}

const variantStyles: Record<CardVariant, string> = {
  surface: 'bg-surface border border-border-subtle rounded-2xl',
  elevated: 'bg-elevated border border-border rounded-2xl',
  interactive: 'bg-surface border border-border-subtle rounded-2xl hover:border-border hover:bg-elevated/70 active:scale-[0.98] transition-all duration-200',
}

export default function Card({ variant = 'surface', children, className = '', ...props }: CardProps) {
  return (
    <div className={`${variantStyles[variant]} p-4 ${className}`} {...props}>
      {children}
    </div>
  )
}
