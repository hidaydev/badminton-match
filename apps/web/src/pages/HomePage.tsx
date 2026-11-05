import { useMemo } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { useCommunity } from '../community/CommunityContext'
import { t } from '../i18n'
import { readLastSession } from '../sessions/lastSession'
import type { LastSession } from '../sessions/lastSession'

type Card = { labelKey: 'home.card.sessions' | 'home.card.rankings' | 'home.card.tournaments' | 'home.card.players'; descriptionKey: 'home.card.sessions.description' | 'home.card.rankings.description' | 'home.card.tournaments.description' | 'home.card.players.description'; path: string; icon: 'sessions' | 'rankings' | 'tournament' | 'players' }

function CardIcon({ name }: { name: Card['icon'] }) {
  if (name === 'sessions') {
    return (
      <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <rect x="3" y="4" width="18" height="18" rx="2" />
        <path d="M16 2v4M8 2v4M3 10h18" />
      </svg>
    )
  }
  if (name === 'rankings') {
    return (
      <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M8 21h8M12 17v4M7 4h10v5a5 5 0 0 1-10 0z" />
        <path d="M17 5h3v2a4 4 0 0 1-4 4M7 5H4v2a4 4 0 0 0 4 4" />
      </svg>
    )
  }
  if (name === 'tournament') {
    return (
      <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
        <path d="M6 3v6a6 6 0 0 0 12 0V3M6 3H4v2a4 4 0 0 0 4 4M18 3h2v2a4 4 0 0 1-4 4M12 15v4M8 21h8" />
      </svg>
    )
  }
  return (
    <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="8" r="4" />
      <path d="M4 21c0-4 3.6-6 8-6s8 2 8 6" />
    </svg>
  )
}

export default function HomePage() {
  const { slug = '' } = useParams<{ slug: string }>()
  const { current } = useCommunity()
  const { user } = useAuth()
  const base = `/c/${encodeURIComponent(slug)}`
  const role = current?.slug === slug ? current.role : null
  // localStorage is the only reader here; recomputing on a community switch is
  // cheaper than an effect that would mirror it into state.
  const lastSession: LastSession | null = useMemo(() => readLastSession(slug), [slug])

  if (current === null) {
    return (
      <section>
        <h2 className="text-lg font-bold text-fg">{t('home.empty')}</h2>
        <p className="mt-2 text-sm text-fg-dim">{t('home.emptyHint')}</p>
        {user?.platformOwner === true && (
          <Link to="/owner/communities" className="mt-4 inline-flex min-h-11 items-center rounded-xl border border-border px-4 text-sm text-fg hover:bg-elevated">
            {t('nav.owner')}
          </Link>
        )}
      </section>
    )
  }

  const cards: Card[] = [
    { labelKey: 'home.card.sessions', descriptionKey: 'home.card.sessions.description', path: `${base}/sessions`, icon: 'sessions' },
    { labelKey: 'home.card.rankings', descriptionKey: 'home.card.rankings.description', path: `${base}/rankings`, icon: 'rankings' },
    { labelKey: 'home.card.players', descriptionKey: 'home.card.players.description', path: `${base}/players`, icon: 'players' },
  ]
  if (role === 'admin' || role === 'host') {
    cards.push({
      labelKey: 'home.card.tournaments',
      descriptionKey: 'home.card.tournaments.description',
      path: `${base}/tournaments`,
      icon: 'tournament',
    })
  }

  return (
    <div className="flex flex-col gap-4 pt-1">
      <Link
        to={`${base}/session/new`}
        className="w-full flex items-center justify-center gap-2 py-4 rounded-xl bg-accent text-slate-950 font-bold text-[1rem] transition-all active:scale-[0.98] hover:brightness-110 shadow-sm"
      >
        <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
          <path d="M12 5v14M5 12h14" />
        </svg>
        {t('home.newSession')}
      </Link>

      {lastSession !== null && (
        <Link
          to={`${base}/sessions/${encodeURIComponent(lastSession.id)}`}
          className="w-full flex items-center gap-3.5 p-3.5 sm:p-4 rounded-xl bg-surface border border-border-subtle hover:border-border active:scale-[0.99] transition-all text-left shadow-sm"
        >
          <div className="w-11 h-11 rounded-lg bg-accent/15 border border-accent/30 text-accent flex items-center justify-center shrink-0">
            <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M6 4l14 8-14 8z" />
            </svg>
          </div>
          <div className="flex flex-col gap-1 flex-1 min-w-0">
            <span className="text-[10px] font-sans font-semibold text-fg-dim uppercase tracking-wider">
              {t('home.continueSession')}
            </span>
            <span className="text-sm sm:text-base font-bold text-fg leading-tight truncate">
              {lastSession.title || t('sessions.untitled')}
            </span>
            <span className="text-[10px] font-mono text-fg-dim">
              {lastSession.date.split('-').reverse().join('-')}
            </span>
          </div>
          <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="text-fg-dim/40 shrink-0">
            <path d="M9 18l6-6-6-6" />
          </svg>
        </Link>
      )}

      <div className="flex flex-col gap-2">
        <p className="text-xs font-sans font-semibold text-fg-dim uppercase tracking-wider px-1">
          {t('home.appSection')}
        </p>
        <div className="grid grid-cols-2 gap-2.5">
          {cards.map((card) => (
            <Link
              key={card.path}
              to={card.path}
              className="flex items-start gap-3 p-3.5 rounded-xl bg-surface border border-border-subtle hover:border-border active:scale-[0.98] transition-all text-left"
            >
              <div className="w-8 h-8 rounded-lg bg-elevated border border-border-subtle flex items-center justify-center shrink-0 text-accent">
                <CardIcon name={card.icon} />
              </div>
              <div className="flex flex-col gap-0.5 min-w-0">
                <span className="text-sm font-semibold text-fg leading-tight">{t(card.labelKey)}</span>
                <span className="text-[11px] text-fg-dim leading-snug">{t(card.descriptionKey)}</span>
              </div>
            </Link>
          ))}
        </div>
      </div>

      {(role === 'admin' || role === 'host' || user?.platformOwner === true) && (
        <div className="flex flex-col gap-2">
          <p className="text-xs font-sans font-semibold text-accent/80 uppercase tracking-wider px-1">
            {t('home.adminSection')}
          </p>
          <div className="grid grid-cols-2 gap-2.5">
            {role === 'admin' && (
              <Link
                to={`${base}/settings`}
                className="flex items-start gap-3 p-3.5 rounded-xl bg-surface border border-border-subtle hover:border-border active:scale-[0.98] transition-all text-left"
              >
                <div className="w-8 h-8 rounded-lg bg-elevated border border-border-subtle flex items-center justify-center shrink-0 text-accent">
                  <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <circle cx="12" cy="12" r="3" />
                    <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h.01a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51h.01a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v.01a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
                  </svg>
                </div>
                <div className="flex flex-col gap-0.5 min-w-0">
                  <span className="text-sm font-semibold text-fg leading-tight">{t('home.card.settings')}</span>
                  <span className="text-[11px] text-fg-dim leading-snug">{t('home.card.settings.description')}</span>
                </div>
              </Link>
            )}
            {(role === 'admin' || role === 'host') && (
              <Link
                to={`${base}/export`}
                className="flex items-start gap-3 p-3.5 rounded-xl bg-surface border border-border-subtle hover:border-border active:scale-[0.98] transition-all text-left"
              >
                <div className="w-8 h-8 rounded-lg bg-elevated border border-border-subtle flex items-center justify-center shrink-0 text-accent">
                  <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3" />
                  </svg>
                </div>
                <div className="flex flex-col gap-0.5 min-w-0">
                  <span className="text-sm font-semibold text-fg leading-tight">{t('home.card.export')}</span>
                  <span className="text-[11px] text-fg-dim leading-snug">{t('home.card.export.description')}</span>
                </div>
              </Link>
            )}
            {user?.platformOwner === true && (
              <Link
                to="/owner/communities"
                className="flex items-start gap-3 p-3.5 rounded-xl bg-surface border border-border-subtle hover:border-border active:scale-[0.98] transition-all text-left"
              >
                <div className="w-8 h-8 rounded-lg bg-elevated border border-border-subtle flex items-center justify-center shrink-0 text-accent">
                  <svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M3 21h18M5 21V7l7-4 7 4v14M9 21v-6h6v6" />
                  </svg>
                </div>
                <div className="flex flex-col gap-0.5 min-w-0">
                  <span className="text-sm font-semibold text-fg leading-tight">{t('nav.owner')}</span>
                  <span className="text-[11px] text-fg-dim leading-snug">{t('home.card.owner.description')}</span>
                </div>
              </Link>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
