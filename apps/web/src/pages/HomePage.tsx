// src/pages/HomePage.tsx: home landing hub and primary navigation.
import { useNavigate } from 'react-router-dom'
import { useState } from 'react'
import { usePwaInstall } from '../hooks/usePwaInstall'
import { useLastSession } from '../hooks/useLastSession'
import { useAdmin } from '../context/AdminContext'
import InstallModal from '../components/InstallModal'
import Icon, { type IconName } from '../components/Icon'
import AdminMenuGrid from '../components/admin/AdminMenuGrid'
import { t } from '../i18n'

const secondary: { icon: IconName; label: string; description: string; to: string }[] = [
  { icon: 'sessions', label: 'Sessions', description: 'Browse past sessions', to: '/sessions' },
  { icon: 'ratings', label: 'Rankings', description: 'Past 12 weeks leaderboard', to: '/rankings' },
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
    <div className="flex flex-col gap-4 pt-1">
      {/* Hero CTA — New Session */}
      <button
        onClick={() => navigate('/session/new')}
        className="w-full flex items-center justify-center gap-2 py-4 rounded-xl bg-accent text-slate-950 font-bold text-[1rem] transition-all active:scale-[0.98] hover:brightness-110 shadow-sm"
      >
        <Icon name="plus" size={20} />
        {t('home.newSession')}
      </button>

      {/* Continue Session Card */}
      {lastSession && (
        <button
          onClick={() => navigate(`/s/${lastSession.id}`)}
          className="w-full flex items-center gap-3.5 p-3.5 sm:p-4 rounded-xl bg-surface border border-border-subtle hover:border-border active:scale-[0.99] transition-all text-left shadow-sm"
        >
          <div className="w-11 h-11 rounded-lg bg-accent/15 border border-accent/30 text-accent flex items-center justify-center shrink-0">
            <Icon name="play" size={20} />
          </div>
          <div className="flex flex-col gap-1 flex-1 min-w-0">
            <span className="text-[10px] font-sans font-semibold text-fg-dim uppercase tracking-wider">
              {t('home.continueSession')}
            </span>
            <span className="text-sm sm:text-base font-bold text-fg leading-tight truncate">
              {lastSession.title || 'Untitled Session'}
            </span>
            <div className="flex items-center gap-2 flex-wrap">
              <span className="text-[10px] font-mono text-fg-dim">
                {lastSession.date.split('-').reverse().join('-')}
              </span>
              <span className="text-[10px] font-mono text-fg-dim/60">·</span>
              <span className="text-[10px] font-mono text-fg-dim">
                {lastSession.playerCount}p · {lastSession.totalGames}g
              </span>
            </div>
          </div>
          <svg
            xmlns="http://www.w3.org/2000/svg"
            width="16"
            height="16"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            className="text-fg-dim/40 shrink-0"
          >
            <path d="M9 18l6-6-6-6" />
          </svg>
        </button>
      )}

      {/* App Grid */}
      <div className="flex flex-col gap-2">
        <p className="text-xs font-sans font-semibold text-fg-dim uppercase tracking-wider px-1">
          {t('home.appSection')}
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
              className="flex items-start gap-3 p-3.5 rounded-xl bg-surface border border-border-subtle hover:border-border active:scale-[0.98] transition-all text-left"
            >
              <div className="w-8 h-8 rounded-lg bg-elevated border border-border-subtle flex items-center justify-center shrink-0 text-accent">
                <Icon name={item.icon} size={18} />
              </div>
              <div className="flex flex-col gap-0.5 min-w-0">
                <span className="text-sm font-semibold text-fg leading-tight">{item.label}</span>
                <span className="text-[11px] text-fg-dim leading-snug">{item.description}</span>
              </div>
            </button>
          ))}

          {isInstallable && (
            <button
              onClick={() => setManualInstallOpen(true)}
              className="flex items-start gap-3 p-3.5 rounded-xl bg-surface border border-border-subtle hover:border-border active:scale-[0.98] transition-all text-left"
            >
              <div className="w-8 h-8 rounded-lg bg-elevated border border-border-subtle flex items-center justify-center shrink-0 text-accent">
                <Icon name="download" size={18} />
              </div>
              <div className="flex flex-col gap-0.5 min-w-0">
                <span className="text-sm font-semibold text-fg leading-tight">{t('home.installApp')}</span>
                <span className="text-[11px] text-fg-dim leading-snug">{t('home.installDesc')}</span>
              </div>
            </button>
          )}
        </div>
      </div>

      {/* Admin Section */}
      {isAdmin && (
        <div className="flex flex-col gap-2">
          <p className="text-xs font-sans font-semibold text-amber-500/80 uppercase tracking-wider px-1">
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
