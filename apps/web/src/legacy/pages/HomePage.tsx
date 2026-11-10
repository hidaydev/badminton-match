// src/pages/HomePage.tsx: home landing hub and primary navigation.
import { useNavigate } from '../router'
import { useState } from 'react'
import { usePwaInstall } from '../../hooks/usePwaInstall'
import { useLatestDraftSession } from '../queries'
import { useAdmin } from '../context/AdminContext'
import { communityHref } from '../../routes.manifest'
import { useCommunity } from '../../community/CommunityContext'
import { useMyPlayer } from '../../players/hooks'
import InstallModal from '../components/InstallModal'
import Icon, { type IconName } from '../components/Icon'
import AdminMenuGrid from '../components/admin/AdminMenuGrid'
import { Button, ButtonLink } from '../../components/Button'
import { Card } from '../../components/Card'
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
  // The server picks the newest draft (session_date desc, updated_at desc,
  // limit 1), so a draft past the first page is still offered. The card has
  // its own loading and error states: a failed read must not look like an
  // empty community.
  const draftQuery = useLatestDraftSession()
  const draftSession = draftQuery.data ?? null
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
        <ButtonLink
          to={communityHref(current?.slug ?? '', '/session/new')}
          className="inline-flex w-full items-center justify-center gap-2 py-4 text-base font-bold shadow-sm"
        >
          <Icon name="plus" size={20} />
          {t('home.newSession')}
        </ButtonLink>
      )}

      {/* Continue Session Card — the newest draft that still needs work. */}
      {draftQuery.isPending && current && (
        <Card padding="md" radius="xl" className="w-full flex items-center gap-3.5" role="status">
          <div className="w-11 h-11 rounded-lg bg-accent/10 shrink-0" />
          <span className="text-sm text-fg-dim">{t('home.continue.loading')}</span>
        </Card>
      )}
      {draftQuery.isError && current && (
        <Card padding="md" radius="xl" className="w-full flex items-center gap-3" role="alert">
          <span className="text-sm text-fg flex-1 min-w-0">{t('home.continue.error')}</span>
          <Button
            variant="secondary"
            size="sm"
            onClick={() => void draftQuery.refetch()}
            className="shrink-0 font-semibold"
          >
            {t('home.continue.retry')}
          </Button>
        </Card>
      )}
      {draftSession && current && (
        <Card
          as="button"
          variant="interactive"
          onClick={() =>
            navigate(
              communityHref(current.slug, `/s/${encodeURIComponent(draftSession.id)}`),
            )
          }
          className="flex items-center gap-3.5 p-3.5 shadow-sm sm:p-4"
        >
          <div className="w-11 h-11 rounded-lg bg-accent/15 border border-accent/30 text-accent flex items-center justify-center shrink-0">
            <Icon name="play" size={20} />
          </div>
          <div className="flex flex-col gap-1 flex-1 min-w-0">
            <span className="text-[10px] font-sans font-semibold text-fg-dim label-meta">
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
          <Icon name="chevron-right" size={16} className="text-fg-dim/40" />
        </Card>
      )}

      {/* App Grid */}
      <div className="flex flex-col gap-2">
        <p className="text-xs font-sans font-semibold text-fg-dim label-meta px-1">
          {t('home.appSection')}
        </p>
        <div className="grid grid-cols-2 gap-2.5">
          {secondary.map((item) => (
            <Card
              as="button"
              key={item.to}
              variant="interactive"
              onClick={() => {
                if (item.to === '/scoreboard') void openScoreboard((path) => { void navigate(path) })
                else void navigate(item.to)
              }}
              className="flex items-start gap-3 p-3.5"
            >
              <div className="w-8 h-8 rounded-lg bg-elevated border border-border-subtle flex items-center justify-center shrink-0 text-accent">
                <Icon name={item.icon} size={18} />
              </div>
              <div className="flex flex-col gap-0.5 min-w-0">
                <span className="text-sm font-semibold text-fg leading-tight">{t(item.label)}</span>
                <span className="text-[11px] text-fg-dim leading-snug">{t(item.description)}</span>
              </div>
            </Card>
          ))}

          {myPlayer !== null && (
            <Card
              as="button"
              variant="interactive"
              onClick={() => navigate(`/rankings/${encodeURIComponent(myPlayer.id)}`)}
              className="flex items-start gap-3 p-3.5"
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
            </Card>
          )}

          {isInstallable && (
            <Card
              as="button"
              variant="interactive"
              onClick={() => setManualInstallOpen(true)}
              className="flex items-start gap-3 p-3.5"
            >
              <div className="w-8 h-8 rounded-lg bg-elevated border border-border-subtle flex items-center justify-center shrink-0 text-accent">
                <Icon name="download" size={18} />
              </div>
              <div className="flex flex-col gap-0.5 min-w-0">
                <span className="text-sm font-semibold text-fg leading-tight">{t('home.installApp')}</span>
                <span className="text-[11px] text-fg-dim leading-snug">{t('home.installDesc')}</span>
              </div>
            </Card>
          )}
        </div>
      </div>

      {/* Admin Section */}
      {isAdmin && (
        <div className="flex flex-col gap-2">
          <p className="text-xs font-sans font-semibold text-amber-500/80 label-meta px-1">
            {t('legacy.admin')}
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
