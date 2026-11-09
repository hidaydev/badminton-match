// src/pages/HomePage.tsx: home landing hub and primary navigation.
import { useNavigate } from '../router'
import { useState } from 'react'
import { usePwaInstall } from '../../hooks/usePwaInstall'
import { useListSessions, isDraftSession } from '../queries'
import { useAdmin } from '../context/AdminContext'
import { communityHref } from '../../routes.manifest'
import { useCommunity } from '../../community/CommunityContext'
import { useMyPlayer } from '../../players/hooks'
import InstallModal from '../components/InstallModal'
import Icon, { type IconName } from '../components/Icon'
import AdminMenuGrid from '../components/admin/AdminMenuGrid'
import { t } from '../../i18n'

type MessageKey = Parameters<typeof t>[0]

const secondary: {
  icon: IconName
  label: MessageKey
  description: MessageKey
  to: string
}[] = [
  { icon: 'sessions', label: 'home.card.sessions', description: 'home.card.sessions.hint', to: '/sessions' },
  { icon: 'players', label: 'home.card.players', description: 'home.card.players.hint', to: '/players' },
  { icon: 'ratings', label: 'home.card.rankings', description: 'home.card.rankings.hint', to: '/rankings' },
  { icon: 'scoreboard', label: 'home.card.scoreboard', description: 'home.card.scoreboard.hint', to: '/scoreboard' },
  { icon: 'tournament', label: 'home.card.tournament', description: 'home.card.tournament.hint', to: '/tournaments' },
  { icon: 'post', label: 'home.card.post', description: 'home.card.post.hint', to: '/instagram-post' },
]

async function openScoreboard(navigate: (path: string) => void) {
  try { await document.documentElement.requestFullscreen() } catch (_error) { void _error }
  try { await screen.orientation.lock('landscape') } catch (_error) { void _error }
  navigate('/scoreboard')
}

export default function HomePage() {
  const navigate = useNavigate()
  const { isAdmin } = useAdmin()
  const { isInstallable, isIos, prompt } = usePwaInstall()
  const { current } = useCommunity()
  // The list endpoint returns newest first (session_date desc, updated_at
  // desc), so the first draft is the one that still needs work. A community
  // with no draft gets no card: there is nothing left to continue.
  const { data: sessions } = useListSessions()
  const draftSession = sessions.find(isDraftSession)
  const myPlayer = useMyPlayer(current?.slug ?? null)
  const [manualInstallOpen, setManualInstallOpen] = useState(false)
  // The install sheet only opens from the "Install App" card. Opening it by
  // itself once a day covered the New Session CTA on the landing screen, so
  // only an explicit tap opens it now.

  async function handleInstall() {
    try {
      await prompt()
      setManualInstallOpen(false)
    } catch (err) {
      console.error('PWA install prompt failed', err)
    }
  }

  return (
    <div className="flex flex-col gap-4 pt-1">
      <h1 className="sr-only">{current?.name ?? t('home.appSection')}</h1>
      {/* Hero CTA — New Session (host/admin only; members read sessions). */}
      {isAdmin && (
        <button
          onClick={() => navigate('/session/new')}
          className="w-full flex items-center justify-center gap-2 py-4 rounded-xl bg-accent text-slate-950 font-bold text-[1rem] transition-all active:scale-[0.98] hover:brightness-110 shadow-sm hit44"
        >
          <Icon name="plus" size={20} />
          {t('home.newSession')}
        </button>
      )}

      {/* Continue Session Card — the newest draft that still needs work. */}
      {draftSession && current && (
        <button
          onClick={() =>
            navigate(
              communityHref(current.slug, `/s/${encodeURIComponent(draftSession.id)}`),
            )
          }
          className="w-full flex items-center gap-3.5 p-3.5 sm:p-4 rounded-xl bg-surface border border-border-subtle hover:border-border active:scale-[0.99] transition-all text-left shadow-sm hit44"
        >
          <div className="w-11 h-11 rounded-lg bg-accent/15 border border-accent/30 text-accent flex items-center justify-center shrink-0">
            <Icon name="play" size={20} />
          </div>
          <div className="flex flex-col gap-1 flex-1 min-w-0">
            <span className="text-[10px] font-sans font-semibold text-fg-dim uppercase tracking-wider">
              {t('home.continueSession')}
            </span>
            <span className="text-sm sm:text-base font-bold text-fg leading-tight truncate">
              {draftSession.title || 'Untitled Session'}
            </span>
            <div className="flex items-center gap-2 flex-wrap">
              <span className="text-[10px] font-mono text-fg-dim">
                {draftSession.date.split('-').reverse().join('-')}
              </span>
              <span className="text-[10px] font-mono text-fg-dim">·</span>
              <span className="text-[10px] font-mono text-fg-dim">
                {draftSession.playerCount}p · {draftSession.totalGames}g
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
              className="flex items-start gap-3 p-3.5 rounded-xl bg-surface border border-border-subtle hover:border-border active:scale-[0.98] transition-all text-left hit44"
            >
              <div className="w-8 h-8 rounded-lg bg-elevated border border-border-subtle flex items-center justify-center shrink-0 text-accent">
                <Icon name={item.icon} size={18} />
              </div>
              <div className="flex flex-col gap-0.5 min-w-0">
                <span className="text-sm font-semibold text-fg leading-tight">{t(item.label)}</span>
                <span className="text-[11px] text-fg-dim leading-snug">{t(item.description)}</span>
              </div>
            </button>
          ))}

          {myPlayer !== null && (
            <button
              onClick={() => navigate(`/rankings/${encodeURIComponent(myPlayer.id)}`)}
              className="flex items-start gap-3 p-3.5 rounded-xl bg-surface border border-border-subtle hover:border-border active:scale-[0.98] transition-all text-left hit44"
            >
              <div className="w-8 h-8 rounded-lg bg-elevated border border-border-subtle flex items-center justify-center shrink-0 text-accent">
                <Icon name="ratings" size={18} />
              </div>
              <div className="flex flex-col gap-0.5 min-w-0">
                <span className="text-sm font-semibold text-fg leading-tight">{t('home.card.myStats')}</span>
                <span className="text-[11px] text-fg-dim leading-snug">
                  {t('home.card.myStats.hint', { name: myPlayer.name })}
                </span>
              </div>
            </button>
          )}

          {isInstallable && (
            <button
              onClick={() => setManualInstallOpen(true)}
              className="flex items-start gap-3 p-3.5 rounded-xl bg-surface border border-border-subtle hover:border-border active:scale-[0.98] transition-all text-left hit44"
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

      {manualInstallOpen && (
        <InstallModal
          isIos={isIos}
          onInstall={handleInstall}
          onClose={() => {
            setManualInstallOpen(false)
          }}
        />
      )}
    </div>
  )
}
