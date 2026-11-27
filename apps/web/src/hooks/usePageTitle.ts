import { useEffect } from 'react'
import { t } from '../i18n'
import type { MessageKey } from '../i18n'

/**
 * The browser tab is the only place some users see which screen they are on, and
 * an installed app keeps a stale title across every push navigation. One hook
 * writes it, so the format lives in one place: "<screen> · Majadu".
 */
export function pageTitle(key: MessageKey): string {
  return `${t(key)} · ${t('app.name')}`
}

/** Sets the tab title for the screen this component renders. */
export function usePageTitle(key: MessageKey): void {
  useEffect(() => {
    document.title = pageTitle(key)
  }, [key])
}

/**
 * The community shell owns many screens and renders them through an `Outlet`,
 * so the title is read from the path rather than passed down. The legacy router
 * reports the path without the community prefix.
 */
const SEGMENT_TITLES: readonly [string, MessageKey][] = [
  ['session', 'wizard.setup.title'],
  ['sessions', 'sessions.title'],
  ['rankings', 'rankings.title'],
  ['players', 'players.title'],
  ['tournaments', 'tournaments.title'],
  ['tournament', 'tournaments.title'],
  ['settings', 'admin.title'],
  ['admin', 'nav.admin'],
  ['instagram-post', 'home.card.post'],
  ['export', 'home.card.post'],
  ['scoreboard', 'scoreboard.title'],
  ['view', 'shared.title'],
  ['s', 'shared.title'],
]

/** The title key for a legacy (slug-less) path. */
export function titleKeyForPath(pathname: string): MessageKey {
  const segments = pathname.split('/').filter(Boolean)
  if (segments.length === 0) return 'nav.home'
  const [first, second] = segments
  // The session wizard's four steps are different screens under one segment.
  if (first === 'session') {
    if (second === 'players') return 'wizard.players.title'
    if (second === 'constraints') return 'wizard.constraints.title'
    if (second === 'generate') return 'wizard.generate.title'
    return 'wizard.setup.title'
  }
  // Two levels look at the screen itself: a player detail is not the roster.
  if (first === 'players' && segments.length > 1) return 'player.title'
  if (first === 'tournaments' && segments.length > 1) return 'tournaments.title'
  const match = SEGMENT_TITLES.find(([segment]) => segment === first)
  return match?.[1] ?? 'nav.home'
}
