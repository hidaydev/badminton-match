// src/components/admin/ActionButton.tsx — Tombol aksi kecil untuk admin pages.
import type { ReactNode } from 'react'

interface ActionButtonProps {
  onClick: () => void
  children: ReactNode
  tone?: 'neutral' | 'amber' | 'red' | 'green'
  disabled?: boolean
}

const tones = {
  neutral: 'border-border-subtle bg-elevated/40 text-fg-dim hover:text-fg hover:border-border',
  amber: 'border-accent/30 bg-accent/10 text-accent hover:bg-accent/20',
  red: 'border-error/30 bg-error/10 text-error hover:bg-error/20',
  green: 'border-success/30 bg-success/10 text-success hover:bg-success/20',
}

export default function ActionButton({ onClick, children, tone = 'neutral', disabled }: ActionButtonProps) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className={`text-xs font-medium px-2.5 py-1 rounded-md border transition-colors disabled:opacity-40 disabled:pointer-events-none shrink-0 ${tones[tone]}`}
    >
      {children}
    </button>
  )
}
