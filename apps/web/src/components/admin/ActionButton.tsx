// src/components/admin/ActionButton.tsx — Tombol aksi kecil untuk admin pages.
import type { ReactNode } from 'react'

interface ActionButtonProps {
  onClick: () => void
  children: ReactNode
  tone?: 'neutral' | 'amber' | 'red' | 'green'
  disabled?: boolean
}

const tones = {
  neutral: 'border-border-subtle bg-elevated/70 text-fg-dim hover:text-fg hover:border-border hover:bg-elevated',
  amber: 'border-amber-700/40 bg-amber-950/30 text-amber-300 hover:bg-amber-900/40 hover:border-amber-600/60',
  red: 'border-error/40 bg-error/10 text-error hover:bg-error/20 hover:border-error/60',
  green: 'border-success/40 bg-success/10 text-success hover:bg-success/20 hover:border-success/60',
}

export default function ActionButton({ onClick, children, tone = 'neutral', disabled }: ActionButtonProps) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className={`text-xs font-semibold px-2.5 py-1.5 rounded-lg border transition-all active:scale-95 disabled:opacity-40 disabled:pointer-events-none shrink-0 ${tones[tone]}`}
    >
      {children}
    </button>
  )
}
