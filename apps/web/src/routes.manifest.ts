/**
 * Route-path helpers. The router itself lives in `App.tsx`; this module only
 * answers questions about a pathname, so it stays free of page imports.
 */

/** `/c/acme/sessions` -> `acme`; `null` outside a community path. */
export function communitySlugFromPath(pathname: string): string | null {
  const match = /^\/c\/([^/]+)/.exec(pathname)
  return match ? decodeURIComponent(match[1]) : null
}
