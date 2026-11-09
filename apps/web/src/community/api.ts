import { request } from '../auth/api'
import type { CommunityRole } from '../auth/api'

/** One registry entry as `GET /c/{slug}/config` reports it. */
export type CommunityConfigEntry = {
  value: unknown
  source: 'platform' | 'community'
  /**
   * Booleans only: true when the platform value is a default the community may
   * turn on rather than a ceiling. A response without the field predates it, so
   * the entry is treated as not widenable.
   */
  widenable?: boolean
}

export type CommunityConfig = Record<string, CommunityConfigEntry>

/** One selectable match format from the platform list. */
export type ScoringPreset = {
  id: string
  label: string
  gamesToWin: number
  pointsToWin: number
  winBy: number
  maxPoints: number
  deuceAt: number | null
  changeEndsAt: number | null
}

/**
 * Both halves of `GET /c/{slug}/config`: the effective settings and the
 * platform's format list. One response carries both, so one request reads
 * both; asking twice for the same document only doubles the wait and gives
 * the screen two failure states for one resource.
 */
export type CommunityConfigBundle = {
  config: CommunityConfig
  presets: ScoringPreset[]
}

export async function fetchCommunityConfigBundle(slug: string): Promise<CommunityConfigBundle> {
  const body = await request<{ effective?: CommunityConfig; scoringPresets?: ScoringPreset[] }>(
    `/c/${encodeURIComponent(slug)}/config`,
  )
  return { config: body.effective ?? {}, presets: body.scoringPresets ?? [] }
}

/**
 * Effective settings for a member of the community named by the slug. The
 * backend derives the community from the path, so no community header exists.
 */
export async function fetchCommunityConfig(slug: string): Promise<CommunityConfig> {
  return (await fetchCommunityConfigBundle(slug)).config
}

/** The platform's format list; reference data, not a community setting. */
export async function fetchScoringPresets(slug: string): Promise<ScoringPreset[]> {
  return (await fetchCommunityConfigBundle(slug)).presets
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

/** One community that opted into the public directory. */
export type DirectoryEntry = {
  slug: string
  name: string
}

/**
 * Communities whose directory flag is on. Public: an account without a
 * membership reads the same list, which is what the join screen needs before it
 * knows any slug.
 */
export async function listDirectory(): Promise<DirectoryEntry[]> {
  const body = await request<{ items: DirectoryEntry[] }>('/directory')
  return body.items
}
