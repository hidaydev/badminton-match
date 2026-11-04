import { request } from '../auth/api'
import type { CommunityRole } from '../auth/api'

export type Member = {
  userId: string
  displayName: string
  role: CommunityRole
  joinedAt: string
}

export type JoinRequest = {
  id: string
  userId: string
  displayName: string
  createdAt: string
}

export type Invite = {
  token: string
  expiresInDays: number
  role: CommunityRole
}

export type RatingSource = {
  id: string
  type: string
  date: string
  sourceId: string
  deltas: number
  finalized: boolean
  finalizedAt: string | null
}

export async function listMembers(slug: string): Promise<Member[]> {
  const body = await request<{ items: Member[] }>(
    `/c/${encodeURIComponent(slug)}/members`,
  )
  return body.items
}

export function setMemberRole(
  slug: string,
  userId: string,
  role: CommunityRole,
): Promise<{ userId: string; role: CommunityRole }> {
  return request<{ userId: string; role: CommunityRole }>(
    `/c/${encodeURIComponent(slug)}/members/${encodeURIComponent(userId)}`,
    { method: 'PATCH', body: JSON.stringify({ role }) },
  )
}

export function removeMember(slug: string, userId: string): Promise<void> {
  return request<void>(
    `/c/${encodeURIComponent(slug)}/members/${encodeURIComponent(userId)}`,
    { method: 'DELETE' },
  )
}

export async function listJoinRequests(slug: string): Promise<JoinRequest[]> {
  const body = await request<{ items: JoinRequest[] }>(
    `/c/${encodeURIComponent(slug)}/join-requests`,
  )
  return body.items
}

export function decideJoinRequest(
  slug: string,
  id: string,
  decision: 'approve' | 'reject',
): Promise<{ status: string }> {
  return request<{ status: string }>(
    `/c/${encodeURIComponent(slug)}/join-requests/${encodeURIComponent(id)}`,
    { method: 'PATCH', body: JSON.stringify({ decision }) },
  )
}

/** The token comes back exactly once; nothing can read it again later. */
export function createInvite(
  slug: string,
  email: string,
  role: CommunityRole,
): Promise<Invite> {
  return request<Invite>(`/c/${encodeURIComponent(slug)}/invites`, {
    method: 'POST',
    body: JSON.stringify({ email, role }),
  })
}

export async function listRatingSources(slug: string): Promise<RatingSource[]> {
  const body = await request<{ items: RatingSource[] }>(
    `/c/${encodeURIComponent(slug)}/rating-sources`,
  )
  return body.items
}

export function setSourceFinalized(
  slug: string,
  id: string,
  finalized: boolean,
): Promise<{ sourceId: string; kind: string; finalized: boolean }> {
  return request<{ sourceId: string; kind: string; finalized: boolean }>(
    `/c/${encodeURIComponent(slug)}/rating-sources/${encodeURIComponent(id)}`,
    { method: 'PATCH', body: JSON.stringify({ finalized }) },
  )
}

export type RebuildResult = { events: number; deltas: number }

export function removeRatingSource(
  slug: string,
  id: string,
): Promise<{ removedDeltas: number; events: number; deltas: number }> {
  return request<{ removedDeltas: number; events: number; deltas: number }>(
    `/c/${encodeURIComponent(slug)}/rating-sources/${encodeURIComponent(id)}`,
    { method: 'DELETE' },
  )
}

export function rebuildRatings(slug: string): Promise<RebuildResult> {
  return request<RebuildResult>(`/c/${encodeURIComponent(slug)}/ratings/rebuild`, {
    method: 'POST',
    body: JSON.stringify({}),
  })
}
