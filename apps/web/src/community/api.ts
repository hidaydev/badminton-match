import { request } from '../auth/api'

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
