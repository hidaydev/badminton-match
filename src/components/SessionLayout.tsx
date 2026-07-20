import { Link, NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom'
import { useStore } from '../store'

const steps = [
  { to: '/session/new', label: 'Setup' },
  { to: '/session/players', label: 'Players' },
  { to: '/session/constraints', label: 'Constraints' },
  { to: '/session/generate', label: 'Generate' },
]

export default function SessionLayout() {
  const locked = useStore((s) => s.session.locked)
  const players = useStore((s) => s.players)
  const playerCount = useStore((s) => s.session.playerCount)
  const hasSchedule = useStore((s) => s.schedule.length > 0)
  const resetSession = useStore((s) => s.resetSession)
  const location = useLocation()
  const navigate = useNavigate()

  const currentIndex = steps.findLastIndex((s) =>
    s.to === '/session/new'
      ? location.pathname === '/session/new'
      : location.pathname.startsWith(s.to)
  )
  const maxReached = Math.max(
    hasSchedule ? 3 : locked && players.length === playerCount ? 2 : locked ? 1 : 0,
    currentIndex
  )
  const isUnlocked = [
    true,
    locked,
    locked && players.length === playerCount,
    locked && players.length === playerCount,
  ]

  return (
    <div className="min-h-screen bg-ground text-fg flex flex-col">
      <header className="border-b border-border-subtle bg-surface/80 backdrop-blur sticky top-0 z-10">
        <div className="max-w-3xl mx-auto px-3 py-3 flex items-center gap-2">
          <button
            onClick={() => navigate(-1)}
            className="p-1.5 rounded-lg text-slate-400 hover:text-white active:scale-90 transition-all shrink-0"
            aria-label="Back"
          >
            <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
              <path d="M15 18l-6-6 6-6"/>
            </svg>
          </button>
          <Link to="/" className="flex items-center gap-2">
            <img src="/logo-192.png" alt="logo" className="w-6 h-6 shrink-0 object-contain" />
            <h1 className="text-sm font-bold text-white tracking-tight whitespace-nowrap">MAJADU APP</h1>
          </Link>
          {locked && (
            <div className="ml-auto flex items-center gap-2 shrink-0">
              <span className="flex items-center gap-1 text-xs text-emerald-400">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-400 shrink-0" />
                Active
              </span>
              <button
                onClick={() => { resetSession(); navigate('/') }}
                className="text-xs text-red-400 hover:text-red-300 transition-colors"
              >
                Reset
              </button>
            </div>
          )}
        </div>

        <nav className="max-w-3xl mx-auto px-3 pb-2">
          <div className="flex items-center">
            {steps.map((s, i) => {
              const isActive = i === currentIndex
              const isDone = i < maxReached && i !== currentIndex
              const disabled = !isUnlocked[i]
              return (
                <div key={s.to} className="flex items-center flex-1 last:flex-none">
                  <NavLink
                    to={s.to}
                    end={s.to === '/session/new'}
                    onClick={disabled ? (e) => e.preventDefault() : undefined}
                    className={`flex flex-col items-center gap-1 ${disabled ? 'cursor-not-allowed' : 'cursor-pointer'}`}
                  >
                    <div className={`w-7 h-7 rounded-full flex items-center justify-center text-xs font-bold border-2 transition-colors ${
                      isActive
                        ? 'bg-indigo-600 border-indigo-500 text-white'
                        : isDone
                        ? 'bg-emerald-900/60 border-emerald-600 text-emerald-400'
                        : 'bg-slate-800 border-slate-700 text-slate-300'
                    }`}>
                      {isDone ? '✓' : i + 1}
                    </div>
                    <span className={`text-[10px] font-medium transition-colors ${
                      isActive ? 'text-indigo-400' : isDone ? 'text-emerald-500' : 'text-slate-400'
                    }`}>
                      {s.label}
                    </span>
                  </NavLink>
                  {i < steps.length - 1 && (
                    <div className={`flex-1 h-px mx-2 mb-4 transition-colors ${i < maxReached ? 'bg-emerald-700' : 'bg-slate-800'}`} />
                  )}
                </div>
              )
            })}
          </div>
        </nav>
      </header>

      <main className="flex-1 max-w-3xl w-full mx-auto px-3 py-4">
        <Outlet />
      </main>
    </div>
  )
}
