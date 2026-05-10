import { useNavigate } from 'react-router-dom'

const menu = [
  { icon: '🏸', label: 'Create Session', description: 'Set up a new game', to: '/session/new', badge: null },
  { icon: '📋', label: 'Sessions', description: 'Browse past sessions', to: '/sessions', badge: null },
  { icon: '👤', label: 'Player History', description: 'Stats & records', to: '/player-history', badge: null },
  { icon: '🏆', label: 'Tournament', description: 'Standings & cup', to: '/tournament', badge: null },
] as const

export default function HomePage() {
  const navigate = useNavigate()
  return (
    <div className="flex flex-col gap-8 pt-6">
      <div className="flex flex-col gap-1">
        <p className="text-[10px] font-mono text-slate-500 tracking-[0.2em] uppercase">Badminton</p>
        <h2 className="text-3xl font-bold text-yellow-400 tracking-tight leading-none">Scheduler</h2>
        <p className="text-slate-500 text-xs mt-2 font-mono">Select an option to get started</p>
      </div>

      <div className="grid grid-cols-2 gap-2.5">
        {menu.map((item) => {
          const disabled = !!item.badge
          return (
            <button
              key={item.to}
              onClick={() => !disabled && navigate(item.to)}
              disabled={disabled}
              className={`
                group relative flex flex-col gap-4 p-5 rounded-2xl text-left
                border transition-all duration-200
                ${disabled
                  ? 'bg-slate-900/40 border-slate-800/60 cursor-not-allowed opacity-60'
                  : 'bg-slate-900 border-slate-800 hover:border-slate-600 hover:bg-slate-800/70 active:scale-[0.98]'
                }
              `}
            >
              {item.badge && (
                <span className="absolute top-3 right-3 text-[9px] font-mono font-bold tracking-widest uppercase bg-amber-500/10 text-amber-500 border border-amber-500/20 rounded px-1.5 py-0.5">
                  {item.badge}
                </span>
              )}
              <span className="text-2xl">{item.icon}</span>
              <div className="flex flex-col gap-0.5">
                <span className="text-sm font-semibold text-white leading-tight">{item.label}</span>
                <span className="text-[11px] text-slate-500">{item.description}</span>
              </div>
              {!disabled && (
                <span className="absolute bottom-4 right-4 text-slate-700 group-hover:text-slate-500 transition-colors text-sm font-mono">
                  →
                </span>
              )}
            </button>
          )
        })}
      </div>
    </div>
  )
}
