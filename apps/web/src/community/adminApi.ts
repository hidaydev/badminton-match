import { request } from '../auth/api'
import type { CommunityRole } from '../auth/api'
import { collectPages } from '../api/paged'
import type { Page } from '../api/paged'

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

export type PendingClaim = {
  claimId: string
  playerId: string
  playerName: string
  userId: string
  displayName: string
  createdAt: string
}

/** The server pages this list; the settings screen still needs every member. */
export function listMembers(slug: string): Promise<Member[]> {
  return collectPages((offset, limit) =>
    request<Page<Member>>(
      `/c/${encodeURIComponent(slug)}/members?limit=${limit}&offset=${offset}`,
    ),
  )
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

export function listJoinRequests(slug: string): Promise<JoinRequest[]> {
  return collectPages((offset, limit) =>
    request<Page<JoinRequest>>(
      `/c/${encodeURIComponent(slug)}/join-requests?limit=${limit}&offset=${offset}`,
    ),
  )
}

export function listPendingClaims(slug: string): Promise<PendingClaim[]> {
  return collectPages((offset, limit) =>
    request<Page<PendingClaim>>(
      `/c/${encodeURIComponent(slug)}/claims?limit=${limit}&offset=${offset}`,
    ),
  )
}

export function decideJoinRequest(
  slug: string,
  id: string,
  decision: 'approve' | 'reject',
  role: CommunityRole = 'member',
): Promise<{ status: string }> {
  return request<{ status: string }>(
    `/c/${encodeURIComponent(slug)}/join-requests/${encodeURIComponent(id)}`,
    { method: 'PATCH', body: JSON.stringify({ decision, role }) },
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
