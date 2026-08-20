// src/components/admin/ActionButton.tsx — Tombol aksi kecil untuk admin pages.
import type { ReactNode } from 'react'

interface ActionButtonProps {
  onClick: () => void
  children: ReactNode
  tone?: 'neutral' | 'amber' | 'red' | 'green'
  disabled?: boolean
}

const tones = {
  neutral: 'border-border text-fg-dim hover:text-fg',
  amber: 'border-amber-700/50 text-amber-300 hover:bg-amber-900/40',
  red: 'border-red-800/50 text-red-400 hover:bg-red-950/40',
  green: 'border-emerald-700/60 text-emerald-400 hover:bg-emerald-950/40',
}

export default function ActionButton({ onClick, children, tone = 'neutral', disabled }: ActionButtonProps) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      className={`text-[10px] font-mono px-2 py-1 rounded border transition-colors disabled:opacity-40 ${tones[tone]}`}
    >
      {children}
    </button>
  )
}
