/**
 * Route-path helpers. `App.tsx` owns the route table itself; this module only
 * answers "what does this pathname mean" and "how is a community path built",
 * so it stays free of page imports and is safe to import from anywhere.
 */

/** `/c/acme/sessions` -> `acme`; `null` outside a community path. */
export function communitySlugFromPath(pathname: string): string | null {
  const match = /^\/c\/([^/]+)/.exec(pathname)
  return match ? decodeURIComponent(match[1]) : null
}

/**
 * Prefix a legacy (slug-less) path with the community segment. Paths that
 * already carry `/c` and the platform-owner tree (`/owner/...`) are absolute, so
 * they pass through unchanged. One implementation for every caller means the
 * legacy router, the community picker and redirects cannot drift apart.
 */
export function communityHref(slug: string, pathname: string): string {
  if (slug === '' || !pathname.startsWith('/')) return pathname
  if (pathname === '/c' || pathname.startsWith('/c/')) return pathname
  if (pathname === '/owner' || pathname.startsWith('/owner/')) return pathname
  if (pathname === '/') return `/c/${encodeURIComponent(slug)}`
  return `/c/${encodeURIComponent(slug)}${pathname}`
}