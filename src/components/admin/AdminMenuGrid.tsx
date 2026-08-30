// src/components/admin/AdminMenuGrid.tsx — grid card menu admin (home page).
// Card mengarah ke /admin/* (pages terpisah).
import { useNavigate } from 'react-router-dom'
import Icon, { type IconName } from '../Icon'

const ITEMS: { icon: IconName; label: string; desc: string; to: string }[] = [
  { icon: 'unlock', label: 'Unlock Session', desc: 'Unlock & delete sessions', to: '/admin/sessions' },
  { icon: 'players', label: 'Players', desc: 'Add, rename, tier', to: '/admin/players' },
  { icon: 'ratings', label: 'Ratings', desc: 'Ingest, revert, rebuild', to: '/admin/ratings' },
  { icon: 'tournament', label: 'Tournament', desc: 'Delete tournaments', to: '/admin/tournaments' },
  { icon: 'season', label: 'Season', desc: 'Close & start new season', to: '/admin/seasons' },
]

export default function AdminMenuGrid() {
  const navigate = useNavigate()
  return (
    <div className="grid grid-cols-2 gap-2.5">
      {ITEMS.map((it) => (
        <button
          key={it.to}
          onClick={() => navigate(it.to)}
          className="flex items-start gap-3 p-4 rounded-lg bg-amber-950/20 border border-amber-800/40 hover:border-amber-700 active:scale-[0.98] transition-all text-left"
        >
          <Icon name={it.icon} size={20} />
          <div className="flex flex-col gap-0.5 min-w-0">
            <span className="text-sm font-semibold text-amber-200 leading-tight">{it.label}</span>
            <span className="text-[11px] text-amber-200/60">{it.desc}</span>
          </div>
        </button>
      ))}
    </div>
  )
}
