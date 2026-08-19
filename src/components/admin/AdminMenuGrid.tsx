// src/components/admin/AdminMenuGrid.tsx — grid card menu admin (home page).
// Card mengarah ke /admin?section=X (AdminPage autofocus section itu).
import { useNavigate } from 'react-router-dom'
import Icon, { type IconName } from '../Icon'

const ITEMS: { icon: IconName; label: string; desc: string; section: string }[] = [
  { icon: 'unlock', label: 'Unlock Session', desc: 'Unlock & delete sessions', section: 'sessions' },
  { icon: 'players', label: 'Players', desc: 'Add, rename, tier, rebaseline', section: 'players' },
  { icon: 'ratings', label: 'Ratings', desc: 'Ingest, revert, rebuild', section: 'ratings' },
  { icon: 'tournament', label: 'Tournament', desc: 'Delete tournaments', section: 'tournament' },
  { icon: 'season', label: 'Season', desc: 'Close & start new season', section: 'season' },
]

export default function AdminMenuGrid() {
  const navigate = useNavigate()
  return (
    <div className="grid grid-cols-2 gap-2.5">
      {ITEMS.map((it) => (
        <button
          key={it.section}
          onClick={() => navigate(`/admin?section=${it.section}`)}
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
