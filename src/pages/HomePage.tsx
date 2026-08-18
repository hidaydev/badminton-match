import { useNavigate } from 'react-router-dom'
import { useState } from 'react'
import { usePwaInstall } from '../hooks/usePwaInstall'
import { useLastSession } from '../hooks/useLastSession'
import InstallModal from '../components/InstallModal'

const secondary = [
  { icon: 'sessions', label: 'Sessions', description: 'Browse past sessions', to: '/sessions' },
  { icon: 'history', label: 'Player History', description: 'Stats & records', to: '/player-history' },
  { icon: 'scoreboard', label: 'Scoreboard', description: 'Live match scoring', to: '/scoreboard' },
  { icon: 'tournament', label: 'Tournament', description: 'Leaderboard & cup', to: '/tournaments' },
  { icon: 'post', label: 'Instagram Post', description: 'Create a post', to: '/instagram-post' },
] as const

function Icon({ name, size = 20 }: { name: string; size?: number }) {
  const common = {
    width: size,
    height: size,
    viewBox: '0 0 24 24',
    fill: 'none',
    stroke: 'currentColor',
    strokeWidth: 1.8,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
  }
  switch (name) {
    case 'plus':
      return <svg {...common}><path d="M12 5v14M5 12h14" /></svg>
    case 'sessions':
      return <svg {...common}><path d="M8 6h13M8 12h13M8 18h13" /><path d="M3 6h.01M3 12h.01M3 18h.01" /></svg>
    case 'history':
      return <svg {...common}><circle cx="12" cy="8" r="4" /><path d="M4 21c0-4 3.6-6 8-6s8 2 8 6" /></svg>
    case 'scoreboard':
      return <svg {...common}><rect x="3" y="5" width="18" height="14" rx="1" /><path d="M8 3v4M16 3v4M3 12h18" /><path d="M7 15l2-2 2 2 2-2 2 2" /></svg>
    case 'tournament':
      return <svg {...common}><path d="M8 21h8M12 17v4M7 4h10v4a5 5 0 0 1-10 0V4z" /><path d="M7 6H3v2a3 3 0 0 0 4 2.8M17 6h4v2a3 3 0 0 1-4 2.8" /></svg>
    case 'post':
      return <svg {...common}><rect x="3" y="3" width="18" height="18" rx="2" /><circle cx="8.5" cy="8.5" r="1.5" /><path d="M21 15l-5-5L5 21" /></svg>
    case 'download':
      return <svg {...common}><path d="M12 3v12M7 10l5 5 5-5" /><path d="M4 21h16" /></svg>
    case 'play':
      return <svg {...common}><path d="M6 4l14 8-14 8V4z" /></svg>
    default:
      return null
  }
}

async function openScoreboard(navigate: (path: string) => void) {
  try { await document.documentElement.requestFullscreen() } catch (_error) { void _error }
  try { await screen.orientation.lock('landscape') } catch (_error) { void _error }
  navigate('/scoreboard')
}

export default function HomePage() {
  const navigate = useNavigate()
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

      {/* Grid sekunder */}
      <div className="flex flex-col gap-2.5">
        <p className="text-[10px] font-mono text-fg-dim uppercase" style={{ letterSpacing: '0.12em' }}>
          App
        </p>
        <div className="grid grid-cols-2 gap-2.5">
          {secondary.map((item) => (
            <button
              key={item.to}
              onClick={() => item.to === '/scoreboard' ? openScoreboard(navigate) : navigate(item.to)}
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