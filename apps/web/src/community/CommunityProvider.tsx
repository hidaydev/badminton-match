import { useCallback, useEffect, useMemo, useSyncExternalStore } from 'react'
import type { ReactNode } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { communitySlugFromPath } from '../routes.manifest'
import { CommunityContext } from './CommunityContext'
import type { CommunityContextValue } from './CommunityContext'
import { communityPath, resolveCommunity } from './selection'
import { readStoredSlug, subscribeStoredSlug, writeStoredSlug } from './storage'

export function CommunityProvider({ children }: { children: ReactNode }) {
  const { memberships } = useAuth()
  const location = useLocation()
  const navigate = useNavigate()

  const pathSlug = communitySlugFromPath(location.pathname)
  // The stored preference is an external store, not a render-time read: every
  // render observes the same value until a write notifies it, and a discarded
  // concurrent render cannot observe a different slug than the write after it.
  const storedSlug = useSyncExternalStore(subscribeStoredSlug, readStoredSlug, () => null)
  const current = resolveCommunity(memberships, pathSlug, storedSlug)

  // Visiting a community the account belongs to makes it the remembered one.
  useEffect(() => {
    if (pathSlug === null) return
    if (!memberships.some((membership) => membership.slug === pathSlug)) return
    writeStoredSlug(pathSlug)
  }, [pathSlug, memberships])

  const select = useCallback(
    (slug: string) => {
      writeStoredSlug(slug)
      const target = communityPath(location.pathname, slug)
      if (target === location.pathname) return
      void navigate({ pathname: target, search: location.search, hash: location.hash })
    },
    [location.pathname, location.search, location.hash, navigate],
  )

  const value = useMemo<CommunityContextValue>(
    () => ({ memberships, current, select }),
    [memberships, current, select],
  )

  return <CommunityContext.Provider value={value}>{children}</CommunityContext.Provider>
}
