import { useNavigate } from 'react-router-dom'
import { useState } from 'react'
import { usePwaInstall } from '../hooks/usePwaInstall'
import { useLastSession } from '../hooks/useLastSession'
import InstallModal from '../components/InstallModal'

const grid = [
  { icon: '🏸', label: 'Create Session', description: 'Set up a new game', to: '/session/new' },
  { icon: '📋', label: 'Sessions', description: 'Browse past sessions', to: '/sessions' },
  { icon: '👤', label: 'Player History', description: 'Stats & records', to: '/player-history' },
  { icon: '🎯', label: 'Scoreboard', description: 'Live match scoring', to: '/scoreboard' },
  { icon: '📸', label: 'Instagram Post', description: 'Create a post from template', to: '/instagram-post' },
  { icon: '🏆', label: 'Tournament', description: 'Leaderboard & cup', to: '/tournament' },
] as const

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
    await prompt()
    localStorage.setItem('pwa-install-shown', today)
    setInstallDismissed(true)
    setManualInstallOpen(false)
  }

  return (
    <div className="flex flex-col gap-6 pt-6">
      <div className="flex flex-col gap-1">
        <p
          className="text-[10px] font-mono text-slate-500 uppercase"
          style={{ letterSpacing: '0.2em' }}
        >
          Badminton
        </p>
        <h2 className="text-3xl font-bold text-yellow-400 tracking-tight leading-none">Scheduler</h2>
        <p className="text-slate-500 text-xs mt-2 font-mono">Select an option to get started</p>
      </div>

      {lastSession && (
        <button
          onClick={() => navigate(`/s/${lastSession.id}`)}
          className="relative overflow-hidden flex items-center gap-4 p-5 rounded-2xl text-left
            bg-slate-900 border border-slate-700 hover:border-slate-500 hover:bg-slate-800/70
            active:scale-98 transition-all duration-200"
        >
          <span className="text-3xl">📋</span>
          <div className="flex flex-col gap-0.5 flex-1 min-w-0">
            <span
              className="text-[10px] font-mono text-slate-500 uppercase"
              style={{ letterSpacing: '0.15em' }}
            >
              Continue Session
            </span>
            <span className="text-base font-bold text-white leading-tight truncate">
              {lastSession.title || 'Untitled Session'}
            </span>
            <span className="text-xs text-slate-400 font-mono">
              {lastSession.date.split('-').reverse().join('-')} · {lastSession.playerCount} players · {lastSession.totalGames} games
            </span>
          </div>
          <span className="text-slate-600 font-mono text-sm shrink-0">→</span>
        </button>
      )}

      {/* 2×N grid */}
      <div className="grid grid-cols-2 gap-2.5">
        {grid.map((item) => (
          <button
            key={item.to}
            onClick={() => item.to === '/scoreboard' ? openScoreboard(navigate) : navigate(item.to)}
            className="group relative flex flex-col gap-4 p-5 rounded-2xl text-left
              border transition-all duration-200
              bg-slate-900 border-slate-800 hover:border-slate-600 hover:bg-slate-800/70 active:scale-98"
          >
            <span className="text-2xl">{item.icon}</span>
            <div className="flex flex-col gap-0.5">
              <span className="text-sm font-semibold text-white leading-tight">{item.label}</span>
              <span className="text-[11px] text-slate-500">{item.description}</span>
            </div>
            <span className="absolute bottom-4 right-4 text-slate-700 group-hover:text-slate-500 transition-colors text-sm font-mono">→</span>
          </button>
        ))}

        {isInstallable && (
          <button
            onClick={() => setManualInstallOpen(true)}
            className="group relative flex flex-col gap-4 p-5 rounded-2xl text-left
              border transition-all duration-200
              bg-slate-900 border-slate-800 hover:border-slate-600 hover:bg-slate-800/70 active:scale-98"
          >
            <span className="text-2xl">📲</span>
            <div className="flex flex-col gap-0.5">
              <span className="text-sm font-semibold text-white leading-tight">Install App</span>
              <span className="text-[11px] text-slate-500">Add to your home screen</span>
            </div>
            <span className="absolute bottom-4 right-4 text-slate-700 group-hover:text-slate-500 transition-colors text-sm font-mono">→</span>
          </button>
        )}
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
