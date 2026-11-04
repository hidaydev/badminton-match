import { useCallback, useEffect, useMemo } from 'react'
import type { ReactNode } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { useAuth } from '../auth/AuthContext'
import { communitySlugFromPath } from '../routes.manifest'
import { CommunityContext } from './CommunityContext'
import type { CommunityContextValue } from './CommunityContext'
import { communityPath, resolveCommunity } from './selection'
import { readStoredSlug, writeStoredSlug } from './storage'

export function CommunityProvider({ children }: { children: ReactNode }) {
  const { memberships } = useAuth()
  const location = useLocation()
  const navigate = useNavigate()

  const pathSlug = communitySlugFromPath(location.pathname)
  const storedSlug = readStoredSlug()
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
      navigate({ pathname: target, search: location.search, hash: location.hash })
    },
    [location.pathname, location.search, location.hash, navigate],
  )

  const value = useMemo<CommunityContextValue>(
    () => ({ memberships, current, select }),
    [memberships, current, select],
  )

  return <CommunityContext.Provider value={value}>{children}</CommunityContext.Provider>
}
