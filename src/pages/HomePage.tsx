import { useNavigate } from 'react-router-dom'
import { useState } from 'react'
import { usePwaInstall } from '../hooks/usePwaInstall'
import { useLastSession } from '../hooks/useLastSession'
import { useAdmin } from '../context/AdminContext'
import InstallModal from '../components/InstallModal'
import Icon, { type IconName } from '../components/Icon'
import AdminMenuGrid from '../components/admin/AdminMenuGrid'

const secondary: { icon: IconName; label: string; description: string; to: string }[] = [
  { icon: 'sessions', label: 'Sessions', description: 'Browse past sessions', to: '/sessions' },
  { icon: 'ratings', label: 'Ratings', description: 'Skill ratings', to: '/ratings' },
  { icon: 'scoreboard', label: 'Scoreboard', description: 'Live match scoring', to: '/scoreboard' },
  { icon: 'tournament', label: 'Tournament', description: 'Leaderboard & cup', to: '/tournaments' },
  { icon: 'post', label: 'Instagram Post', description: 'Create a post', to: '/instagram-post' },
] as const

async function openScoreboard(navigate: (path: string) => void) {
  try { await document.documentElement.requestFullscreen() } catch (_error) { void _error }
  try { await screen.orientation.lock('landscape') } catch (_error) { void _error }
  navigate('/scoreboard')
}

export default function HomePage() {
  const navigate = useNavigate()
  const { isAdmin } = useAdmin()
  const { isInstallable, isIos, prompt } = usePwaInstall()
  const { lastSession } = useLastSession()
  const [installDismissed, setInstallDismissed] = useState(false)
  const [manualInstallOpen, setManualInstallOpen] = useState(false)
  const today = new Date().toDateString()
  const modalOpen =
    manualInstallOpen || (
      isInstallable &&
      !installDismissed &&
      localStorage.getItem('pwa-install-shown') !== today
    )

  async function handleInstall() {
    try {
      await prompt()
      localStorage.setItem('pwa-install-shown', today)
      setInstallDismissed(true)
      setManualInstallOpen(false)
    } catch (err) {
      console.error('PWA install prompt failed', err)
    }
  }

  return (
    <div className="flex flex-col gap-5 pt-2">
      {/* Hero CTA — action harian */}
      <button
        onClick={() => navigate('/session/new')}
        className="w-full flex items-center justify-center gap-2 py-4 rounded-lg bg-accent text-slate-950 font-bold text-[1rem] transition-all active:scale-[0.98] hover:brightness-110"
      >
        <Icon name="plus" size={20} />
        New Session
      </button>

      {lastSession && (
        <button
          onClick={() => navigate(`/s/${lastSession.id}`)}
          className="flex items-center gap-3 p-4 rounded-lg bg-surface border border-border-subtle hover:border-border active:scale-[0.98] transition-all text-left"
        >
          <Icon name="play" size={20} />
          <div className="flex flex-col gap-0.5 flex-1 min-w-0">
            <span className="text-[10px] font-mono text-fg-dim uppercase" style={{ letterSpacing: '0.12em' }}>
              Continue Session
            </span>
            <span className="text-[1rem] font-bold text-fg leading-tight truncate">
              {lastSession.title || 'Untitled Session'}
            </span>
            <span className="text-xs text-fg-dim font-mono">
              {lastSession.date.split('-').reverse().join('-')} · {lastSession.playerCount} players · {lastSession.totalGames} games
            </span>
          </div>
        </button>
      )}

      {/* Grid sekunder — menu utama */}
      <div className="flex flex-col gap-2.5">
        <p className="text-[10px] font-mono text-fg-dim uppercase" style={{ letterSpacing: '0.12em' }}>
          App
        </p>
        <div className="grid grid-cols-2 gap-2.5">
          {secondary.map((item) => (
            <button
              key={item.to}
              onClick={() =>
                item.to === '/scoreboard'
                  ? openScoreboard(navigate)
                  : navigate(item.to)
              }
              className="flex items-start gap-3 p-4 rounded-lg bg-surface border border-border-subtle hover:border-border active:scale-[0.98] transition-all text-left"
            >
              <Icon name={item.icon} size={20} />
              <div className="flex flex-col gap-0.5 min-w-0">
                <span className="text-sm font-semibold text-fg leading-tight">{item.label}</span>
                <span className="text-[11px] text-fg-dim">{item.description}</span>
              </div>
            </button>
          ))}

          {isInstallable && (
            <button
              onClick={() => setManualInstallOpen(true)}
              className="flex items-start gap-3 p-4 rounded-lg bg-surface border border-border-subtle hover:border-border active:scale-[0.98] transition-all text-left"
            >
              <Icon name="download" size={20} />
              <div className="flex flex-col gap-0.5 min-w-0">
                <span className="text-sm font-semibold text-fg leading-tight">Install App</span>
                <span className="text-[11px] text-fg-dim">Add to home screen</span>
              </div>
            </button>
          )}
        </div>
      </div>

      {/* Section ADMIN — muncul permanen kalau isAdmin */}
      {isAdmin && (
        <div className="flex flex-col gap-2.5">
          <p className="text-[10px] font-mono text-amber-500/80 uppercase" style={{ letterSpacing: '0.12em' }}>
            Admin
          </p>
          <AdminMenuGrid />
        </div>
      )}

      {modalOpen && (
        <InstallModal
          isIos={isIos}
          onInstall={handleInstall}
          onClose={() => {
            localStorage.setItem('pwa-install-shown', today)
            setInstallDismissed(true)
            setManualInstallOpen(false)
          }}
        />
      )}
    </div>
  )
}
