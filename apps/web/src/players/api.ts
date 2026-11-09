import { request } from '../auth/api'
import { collectPages } from '../api/paged'
import type { PlayerClaim, PlayerClaimPage } from '@majadu/web-client'

/** A player row as the API returns it. `aliases` only comes back per player. */
export type Player = {
  id: string
  name: string
  gender: 'M' | 'F'
  tier: string | null
  userId: string | null
  createdAt: string
  updatedAt: string
  aliases?: string[]
  /** Set per player; true when the viewer already owns a player here. */
  viewerOwnsPlayer?: boolean
}

export type { PlayerClaim }

export type ClaimStatus = PlayerClaim['status']

export type PlayerFilter = {
  q?: string
  tier?: string | null
  cursor?: string | null
  limit?: number
}

/** The list is keyset-paginated; the page size is the caller's, within the platform ceiling. */
export const PLAYER_PAGE = 50

function queryString(filter: PlayerFilter): string {
  const params = new URLSearchParams()
  if (filter.q !== undefined && filter.q !== '') params.set('q', filter.q)
  if (filter.tier !== undefined && filter.tier !== null) params.set('tier', filter.tier)
  if (filter.cursor !== undefined && filter.cursor !== null) params.set('cursor', filter.cursor)
  params.set('limit', String(filter.limit ?? PLAYER_PAGE))
  return params.toString()
}

export async function listPlayers(
  slug: string,
  filter: PlayerFilter = {},
): Promise<Player[]> {
  const body = await request<{ items: Player[] }>(
    `/c/${encodeURIComponent(slug)}/players?${queryString(filter)}`,
  )
  return body.items
}

export function getPlayer(slug: string, id: string): Promise<Player> {
  return request<Player>(
    `/c/${encodeURIComponent(slug)}/players/${encodeURIComponent(id)}`,
  )
}

/**
 * The player this account owns in the community, or null when it has no
 * approved claim. Served by the list route so the roster and the shortcut read
 * the same shape.
 */
export async function getMyPlayer(slug: string): Promise<Player | null> {
  const body = await request<{ items: Player[] }>(
    `/c/${encodeURIComponent(slug)}/players?mine=1`,
  )
  return body.items[0] ?? null
}

export type NewPlayer = {
  name: string
  gender?: 'M' | 'F'
  tier?: string
  aliases?: string[]
}

export function createPlayer(slug: string, input: NewPlayer): Promise<Player> {
  return request<Player>(`/c/${encodeURIComponent(slug)}/players`, {
    method: 'POST',
    body: JSON.stringify(input),
  })
}

export type PlayerPatch = {
  name?: string
  gender?: 'M' | 'F'
  /** `null` clears the grade; omitting the field leaves it alone. */
  tier?: string | null
  aliases?: string[]
}

export function updatePlayer(
  slug: string,
  id: string,
  patch: PlayerPatch,
): Promise<Player> {
  return request<Player>(`/c/${encodeURIComponent(slug)}/players/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    body: JSON.stringify(patch),
  })
}

export function deletePlayer(slug: string, id: string): Promise<void> {
  return request<void>(
    `/c/${encodeURIComponent(slug)}/players/${encodeURIComponent(id)}`,
    { method: 'DELETE' },
  )
}

export function claimPlayer(
  slug: string,
  id: string,
): Promise<{ playerId: string; status: string }> {
  return request<{ playerId: string; status: string }>(
    `/c/${encodeURIComponent(slug)}/players/${encodeURIComponent(id)}/claims`,
    { method: 'POST' },
  )
}

export function listClaims(slug: string, id: string): Promise<PlayerClaim[]> {
  return collectPages((offset, limit) =>
    request<PlayerClaimPage>(
      `/c/${encodeURIComponent(slug)}/players/${encodeURIComponent(id)}/claims?limit=${limit}&offset=${offset}`,
    ),
  )
}

/** `reason` is required by the server when releasing someone else's claim. */
export type ClaimDecision =
  | { decision: 'approve' | 'reject'; reason?: string }
  | { action: 'release'; reason: string }

export function decideClaim(
  slug: string,
  playerId: string,
  claimId: string,
  decision: ClaimDecision,
): Promise<{ claimId: string; status: string }> {
  return request<{ claimId: string; status: string }>(
    `/c/${encodeURIComponent(slug)}/players/${encodeURIComponent(playerId)}/claims/${encodeURIComponent(claimId)}`,
    { method: 'PATCH', body: JSON.stringify(decision) },
  )
}

/** Releases the caller's own approved claim; admins have the decide route. */
export function releaseOwnClaim(
  slug: string,
  playerId: string,
): Promise<{ claimId: string; status: string }> {
  return request<{ claimId: string; status: string }>(
    `/c/${encodeURIComponent(slug)}/players/${encodeURIComponent(playerId)}/claim`,
    { method: 'DELETE' },
  )
}

export type MergeResult = {
  targetPlayerId: string
  sourcePlayerId: string
  aliasesMoved: number
  claimsMoved: number
  deltasMoved: number
  snapshotsMoved: number
  achievementsMoved: number
  pairsMoved: number
  ratingStateMoved: number
}

export function mergePlayers(
  slug: string,
  targetPlayerId: string,
  sourcePlayerId: string,
): Promise<MergeResult> {
  return request<MergeResult>(
    `/c/${encodeURIComponent(slug)}/players/${encodeURIComponent(targetPlayerId)}/merge`,
    { method: 'POST', body: JSON.stringify({ sourcePlayerId }) },
  )
}

/** Player tiers, shared by the roster and player forms. */
export const TIERS: readonly string[] = ['D', 'D+', 'C', 'C+', 'B', 'B+', 'A', 'A+']
