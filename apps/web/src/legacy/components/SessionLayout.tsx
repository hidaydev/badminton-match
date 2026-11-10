import { Link, Outlet, useLocation, useNavigate } from '../router'
import { useStore } from '../store'
import { t } from '../../i18n'
import { SkipLink } from '../../components/SkipLink'
import Icon from '../../components/Icon'
import { PAGE_COLUMN } from '../../components/Page'

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

  const currentIndex = Math.max(
    0,
    steps.findLastIndex((s) =>
      s.to === '/session/new'
        ? location.pathname === '/session/new'
        : location.pathname.startsWith(s.to)
    )
  )
  const maxReached = Math.max(
    hasSchedule ? 3 : locked && players.length === playerCount ? 2 : locked ? 1 : 0,
    currentIndex
  )

  return (
    <div className="min-h-screen bg-ground text-fg flex flex-col">
      <SkipLink />
      <header className="border-b border-border-subtle bg-surface sticky top-0 z-10 pt-[env(safe-area-inset-top)]">
        <div className={`${PAGE_COLUMN} py-2.5 flex items-center gap-2`}>
          <button
            onClick={() => navigate(-1)}
            className="flex h-11 w-11 -ml-[13px] -mr-[7px] -my-[7px] items-center justify-center rounded-lg text-fg-dim hover:text-fg active:scale-90 transition-[color,transform] shrink-0"
            aria-label={t('shell.back')}
          >
            <Icon name="chevron-left" size={18} />
          </button>
          <Link to="/" className="flex min-h-11 -my-[10px] items-center gap-2">
            <img src="/logo-192.png" alt="" className="w-6 h-6 shrink-0 object-contain" />
            <span className="text-sm font-bold text-fg tracking-tight whitespace-nowrap">MAJADU</span>
          </Link>
          {locked && (
            <div className="ml-auto flex items-center gap-2 shrink-0">
              <span className="flex items-center gap-1.5 text-xs text-fg-dim">
                <span className="w-1.5 h-1.5 rounded-full bg-success shrink-0" />
                {t('legacy.active')}
              </span>
              <button
                onClick={() => { resetSession(); void navigate('/') }}
                className="inline-flex min-h-11 min-w-11 -my-[10px] items-center justify-center rounded-lg border border-border-subtle px-2 py-1 text-xs text-fg-dim hover:text-error transition-colors"
              >
                {t('legacy.reset')}
              </button>
            </div>
          )}
        </div>

        {/* Progress: 4 segmen tipis (indikator — navigasi via Back/Next di konten) */}
        <div className={`${PAGE_COLUMN} pb-2`}>
          <div className="flex items-center gap-2">
            <div className="flex gap-1 flex-1">
              {steps.map((s, i) => {
                const done = i < maxReached
                const active = i === currentIndex
                return (
                  <div
                    key={s.to}
                    aria-hidden
                    className={`h-1 flex-1 rounded-full transition-colors ${
                      active || done ? 'bg-accent' : 'bg-slate-700'
                    }`}
                  />
                )
              })}
            </div>
            <span className="text-[10px] font-sans text-fg-dim uppercase shrink-0" style={{ letterSpacing: '0.08em' }}>
              {currentIndex + 1} · {steps[currentIndex].label}
            </span>
          </div>
        </div>
      </header>

      <main id="main" className={`flex-1 ${PAGE_COLUMN} py-4 pb-[env(safe-area-inset-bottom)]`}>
        <Outlet />
      </main>
    </div>
  )
}
