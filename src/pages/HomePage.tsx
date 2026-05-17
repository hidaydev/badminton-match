import { useNavigate } from 'react-router-dom'
import { useState, useEffect } from 'react'
import { usePwaInstall } from '../hooks/usePwaInstall'
import InstallModal from '../components/InstallModal'

const grid = [
  { icon: '🏸', label: 'Create Session', description: 'Set up a new game', to: '/session/new' },
  { icon: '📋', label: 'Sessions', description: 'Browse past sessions', to: '/sessions' },
  { icon: '👤', label: 'Player History', description: 'Stats & records', to: '/player-history' },
  { icon: '🎯', label: 'Scoreboard', description: 'Live match scoring', to: '/scoreboard' },
  { icon: '📸', label: 'Instagram Post', description: 'Create a post from template', to: '/instagram-post' },
] as const

async function openScoreboard(navigate: (path: string) => void) {
  try { await document.documentElement.requestFullscreen() } catch {}
  try { await screen.orientation.lock('landscape') } catch {}
  navigate('/scoreboard')
}

export default function HomePage() {
  const navigate = useNavigate()
  const { isInstallable, isIos, prompt } = usePwaInstall()
  const [modalOpen, setModalOpen] = useState(false)

  useEffect(() => {
    if (!isInstallable) return
    const today = new Date().toDateString()
    const lastShown = localStorage.getItem('pwa-install-shown')
    if (lastShown === today) return
    setModalOpen(true)
    localStorage.setItem('pwa-install-shown', today)
  }, [isInstallable])

  async function handleInstall() {
    await prompt()
    setModalOpen(false)
  }

  return (
    <div className="flex flex-col gap-6 pt-6">
      <div className="flex flex-col gap-1">
        <p className="text-[10px] font-mono text-slate-500 tracking-[0.2em] uppercase">Badminton</p>
        <h2 className="text-3xl font-bold text-yellow-400 tracking-tight leading-none">Scheduler</h2>
        <p className="text-slate-500 text-xs mt-2 font-mono">Select an option to get started</p>
      </div>

      {/* Tournament hero */}
      <button
        onClick={() => navigate('/tournament')}
        className="relative overflow-hidden flex items-center gap-4 p-5 rounded-2xl text-left
          bg-gradient-to-br from-amber-900 via-amber-700 to-amber-600
          border border-amber-600/40 hover:brightness-110 active:scale-[0.98] transition-all duration-200"
      >
        <img
          src="/tournament-badge.png"
          alt=""
          className="absolute right-[-10px] top-1/2 -translate-y-1/2 w-24 h-24 object-contain opacity-20 pointer-events-none"
        />
        <span className="text-3xl relative z-10">🏆</span>
        <div className="relative z-10">
          <span className="text-base font-bold text-white leading-tight block">Tournament</span>
          <span className="text-xs text-amber-200/70">Leaderboard & cup</span>
        </div>
      </button>

      {/* 2×N grid */}
      <div className="grid grid-cols-2 gap-2.5">
        {grid.map((item) => (
          <button
            key={item.to}
            onClick={() => item.to === '/scoreboard' ? openScoreboard(navigate) : navigate(item.to)}
            className="group relative flex flex-col gap-4 p-5 rounded-2xl text-left
              border transition-all duration-200
              bg-slate-900 border-slate-800 hover:border-slate-600 hover:bg-slate-800/70 active:scale-[0.98]"
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
            onClick={() => setModalOpen(true)}
            className="group relative flex flex-col gap-4 p-5 rounded-2xl text-left
              border transition-all duration-200
              bg-slate-900 border-slate-800 hover:border-slate-600 hover:bg-slate-800/70 active:scale-[0.98]"
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
          onClose={() => setModalOpen(false)}
        />
      )}
    </div>
  )
}
