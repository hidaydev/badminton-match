import type { Membership } from '../auth/api'
import { communityHref } from '../routes.manifest'
import { matchMembership } from './membership'

/**
 * Resolve the community the shell shows. A slug in the URL is an explicit
 * request for that community, so it is resolved on its own: when the account
 * is not a member, the answer is `null` and the shell says so instead of
 * quietly showing a different one. Without a URL slug the stored choice wins,
 * then the first membership.
 */
export function resolveCommunity(
  memberships: Membership[],
  pathSlug: string | null,
  storedSlug: string | null,
): Membership | null {
  if (pathSlug !== null) return matchMembership(memberships, pathSlug)
  return matchMembership(memberships, storedSlug) ?? memberships[0] ?? null
}

/**
 * Swap the community segment while keeping the rest of the path, so switching
 * on `/c/acme/sessions` lands on `/c/beta/sessions`.
 */
export function communityPath(pathname: string, slug: string): string {
  const suffix = pathname.replace(/^\/c\/[^/]+/, '')
  return communityHref(slug, suffix === pathname || suffix === '' ? '/' : suffix)
}
