import { request } from '../auth/api'
import type { CommunityRole } from '../auth/api'

/** One registry entry as `GET /c/{slug}/config` reports it. */
export type CommunityConfigEntry = {
  value: unknown
  source: 'platform' | 'community'
}

export type CommunityConfig = Record<string, CommunityConfigEntry>

/**
 * Effective settings for a member of the community named by the slug. The
 * backend derives the community from the path, so no community header exists.
 */
export async function fetchCommunityConfig(slug: string): Promise<CommunityConfig> {
  const body = await request<{ effective: CommunityConfig }>(
    `/c/${encodeURIComponent(slug)}/config`,
  )
  return body.effective
}

/**
 * Narrow one or more community values. The server refuses anything above the
 * platform value, so this is not an arbitrary write. The write answers with the
 * overrides only, so the merged view is read back.
 */
export async function updateCommunityConfig(
  slug: string,
  patch: Record<string, unknown>,
): Promise<CommunityConfig> {
  await request<{ values: unknown }>(`/c/${encodeURIComponent(slug)}/settings`, {
    method: 'PATCH',
    body: JSON.stringify(patch),
  })
  return fetchCommunityConfig(slug)
}

/**
 * Ask an admin to add this account. The API answers 202 for an unknown slug, a
 * community that is not accepting and a pending request alike, so the screen
 * must not claim more than "sent".
 */
export async function requestToJoin(slug: string): Promise<void> {
  await request<{ status: string }>(`/c/${encodeURIComponent(slug)}/join-requests`, {
    method: 'POST',
    body: '{}',
  })
}

/** What the invitation grants; the token itself is single use and expires. */
export type AcceptedInvite = {
  communityId: string
  role: CommunityRole
}

/**
 * Single-use, address-bound and signed in only. The response names the
 * community by id, so the caller re-reads the membership list to learn its slug.
 */
export function acceptInvite(token: string): Promise<AcceptedInvite> {
  return request<AcceptedInvite>(`/invites/${encodeURIComponent(token)}/accept`, {
    method: 'POST',
  })
}
