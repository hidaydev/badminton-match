import type { Membership } from '../auth/api'
import { communityHref } from '../routes.manifest'

/**
 * Resolve the community the shell shows: the slug in the URL wins when the user
 * belongs to it, then the stored slug, then the first membership.
 */
export function resolveCommunity(
  memberships: Membership[],
  pathSlug: string | null,
  storedSlug: string | null,
): Membership | null {
  const find = (slug: string | null) =>
    slug === null ? null : memberships.find((membership) => membership.slug === slug) ?? null

  return find(pathSlug) ?? find(storedSlug) ?? memberships[0] ?? null
}

/**
 * Swap the community segment while keeping the rest of the path, so switching
 * on `/c/acme/sessions` lands on `/c/beta/sessions`.
 */
export function communityPath(pathname: string, slug: string): string {
  const suffix = pathname.replace(/^\/c\/[^/]+/, '')
  return communityHref(slug, suffix === pathname || suffix === '' ? '/' : suffix)
}
