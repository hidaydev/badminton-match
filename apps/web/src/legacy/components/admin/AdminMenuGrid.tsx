// src/components/admin/AdminMenuGrid.tsx — grid card menu admin (home page).
// The cards point at /admin/* (separate pages). Settings and ratings are for
// community admins only; a host gets sessions and tournaments.
import { useNavigate } from '../../router'
import { useAdmin } from '../../context/AdminContext'
import Icon, { type IconName } from '../Icon'

type Item = { icon: IconName; label: string; desc: string; to: string; adminOnly?: boolean }

const ITEMS: Item[] = [
  { icon: 'unlock', label: 'Unlock Session', desc: 'Unlock & delete sessions', to: '/admin/sessions' },
  { icon: 'tournament', label: 'Tournament', desc: 'Delete tournaments', to: '/admin/tournaments' },
  { icon: 'ratings', label: 'Ratings', desc: 'Ingest, revert, rebuild', to: '/admin/ratings', adminOnly: true },
  { icon: 'admin', label: 'Settings', desc: 'Members, invites, join requests', to: '/settings', adminOnly: true },
]

export default function AdminMenuGrid() {
  const navigate = useNavigate()
  const { isAdminRole } = useAdmin()
  const items = ITEMS.filter((item) => !item.adminOnly || isAdminRole)

  return (
    <div className="grid grid-cols-2 gap-2.5">
      {items.map((it) => (
        <button
          key={it.to}
          onClick={() => navigate(it.to)}
          className="flex items-start gap-3 p-3.5 rounded-xl bg-surface border border-border-subtle hover:border-border active:scale-[0.98] transition-all text-left shadow-xs hit44"
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
