/* eslint-disable react-refresh/only-export-components */
import { createContext, useCallback, useContext, useMemo } from 'react'
import type { ReactNode } from 'react'
import {
  Link as RouterLink,
  Navigate as RouterNavigate,
  Outlet as RouterOutlet,
  useLocation as useRouterLocation,
  useNavigate as useRouterNavigate,
  useParams as useRouterParams,
  useSearchParams as useRouterSearchParams,
} from 'react-router-dom'
import type {
  LinkProps,
  Location,
  NavigateFunction,
  NavigateOptions,
  NavigateProps,
  To,
} from 'react-router-dom'
import { communityHref } from '../routes.manifest'

/**
 * The v1 tree speaks slug-less paths (`/sessions`, `/session/new`). The v2 app
 * keeps one canonical prefix, so every legacy navigation is wrapped here once
 * instead of editing a hundred call sites. `useLocation` reports the stripped
 * path, which is what the old layouts compare against.
 */
const LegacySlugContext = createContext<string>('')

export function LegacySlugProvider({ slug, children }: { slug: string; children: ReactNode }) {
  return <LegacySlugContext.Provider value={slug}>{children}</LegacySlugContext.Provider>
}

export function useLegacySlug(): string {
  return useContext(LegacySlugContext)
}

function prefixTo(slug: string, to: To): To {
  if (typeof to === 'string') return communityHref(slug, to)
  if (to.pathname === undefined) return to
  return { ...to, pathname: communityHref(slug, to.pathname) }
}

export function Link({ to, ...props }: LinkProps) {
  const slug = useLegacySlug()
  return <RouterLink {...props} to={prefixTo(slug, to)} />
}

export function Navigate({ to, ...props }: NavigateProps) {
  const slug = useLegacySlug()
  return <RouterNavigate {...props} to={prefixTo(slug, to)} />
}

export function useNavigate(): NavigateFunction {
  const navigate = useRouterNavigate()
  const slug = useLegacySlug()
  return useCallback(
    (to: To | number, options?: NavigateOptions) => {
      if (typeof to === 'number') {
        void navigate(to)
        return
      }
      void navigate(prefixTo(slug, to), options)
    },
    [navigate, slug],
  )
}

export function useLocation(): Location {
  const location = useRouterLocation()
  const slug = useLegacySlug()
  return useMemo(() => {
    if (slug === '') return location
    const base = `/c/${encodeURIComponent(slug)}`
    const pathname =
      location.pathname === base
        ? '/'
        : location.pathname.startsWith(`${base}/`)
          ? location.pathname.slice(base.length)
          : location.pathname
    return { ...location, pathname }
  }, [location, slug])
}

export { RouterOutlet as Outlet }
export { useRouterParams as useParams }
export { useRouterSearchParams as useSearchParams }
