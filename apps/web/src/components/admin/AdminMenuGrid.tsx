// src/components/admin/AdminMenuGrid.tsx — grid card menu admin (home page).
// Card mengarah ke /admin/* (pages terpisah).
import { useNavigate } from 'react-router-dom'
import Icon, { type IconName } from '../Icon'

const ITEMS: { icon: IconName; label: string; desc: string; to: string }[] = [
  { icon: 'unlock', label: 'Unlock Session', desc: 'Unlock & delete sessions', to: '/admin/sessions' },
  { icon: 'players', label: 'Players', desc: 'Add, rename, tier', to: '/admin/players' },
  { icon: 'ratings', label: 'Ratings', desc: 'Ingest, revert, rebuild', to: '/admin/ratings' },
  { icon: 'tournament', label: 'Tournament', desc: 'Delete tournaments', to: '/admin/tournaments' },
]

export default function AdminMenuGrid() {
  const navigate = useNavigate()
  return (
    <div className="grid grid-cols-2 gap-2.5">
      {ITEMS.map((it) => (
        <button
          key={it.to}
          onClick={() => navigate(it.to)}
          className="flex items-start gap-3 p-3.5 rounded-xl bg-surface border border-border-subtle hover:border-border active:scale-[0.98] transition-all text-left shadow-xs"
        >
          <div className="w-8 h-8 rounded-lg bg-elevated border border-border-subtle flex items-center justify-center shrink-0 text-accent">
            <Icon name={it.icon} size={18} />
          </div>
          <div className="flex flex-col gap-0.5 min-w-0">
            <span className="text-sm font-semibold text-fg leading-tight">{it.label}</span>
            <span className="text-[11px] text-fg-dim leading-snug">{it.desc}</span>
          </div>
        </button>
      ))}
    </div>
  )
}
