import { ApiError } from '../auth/api'
import { request } from '../auth/api'
import type { SessionGame } from './api'

/** Every session write carries the version it saw, so a stale tab cannot win. */
function ifMatch(version: number): HeadersInit {
  return { 'If-Match': `"${version}"` }
}

export function lockSession(slug: string, id: string, version: number): Promise<void> {
  return request<void>(`/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(id)}/lock`, {
    method: 'POST',
    headers: ifMatch(version),
  })
}

export function unlockSession(slug: string, id: string, version: number): Promise<void> {
  return request<void>(
    `/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(id)}/unlock`,
    { method: 'POST', headers: ifMatch(version) },
  )
}

export type GameScore = { scoreA: number | null; scoreB: number | null }

export function saveGame(
  slug: string,
  id: string,
  gameKey: string,
  score: GameScore,
  version: number,
): Promise<void> {
  return request<void>(
    `/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(id)}/games/${encodeURIComponent(gameKey)}`,
    { method: 'PATCH', headers: ifMatch(version), body: JSON.stringify(score) },
  )
}

export function skipGame(
  slug: string,
  id: string,
  gameKey: string,
  version: number,
): Promise<void> {
  return request<void>(
    `/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(id)}/games/${encodeURIComponent(gameKey)}/skip`,
    { method: 'PATCH', headers: ifMatch(version) },
  )
}

/** Replaces the whole schedule; the caller sends every game it wants to keep. */
export function putSchedule(
  slug: string,
  id: string,
  games: readonly SessionGame[],
  version: number,
): Promise<void> {
  const body = {
    games: games.map((game) => ({
      round: game.round,
      court: game.court,
      sideA: game.sideA,
      sideB: game.sideB,
    })),
  }
  return request<void>(`/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(id)}/schedule`, {
    method: 'PUT',
    headers: ifMatch(version),
    body: JSON.stringify(body),
  })
}

export function setAbsent(
  slug: string,
  id: string,
  playerIds: readonly string[],
  version: number,
): Promise<void> {
  return request<void>(`/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(id)}/absent`, {
    method: 'PATCH',
    headers: ifMatch(version),
    body: JSON.stringify({ playerIds }),
  })
}

export type ShareLink = { code: string; sessionId: string }

/** The live code, or null when this session has none yet. */
export async function getShareLink(slug: string, id: string): Promise<ShareLink | null> {
  try {
    return await request<ShareLink>(
      `/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(id)}/share`,
      {},
    )
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) return null
    throw error
  }
}

export function createShareLink(slug: string, id: string): Promise<ShareLink> {
  return request<ShareLink>(
    `/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(id)}/share`,
    { method: 'POST' },
  )
}

export function deleteShareLink(slug: string, id: string): Promise<void> {
  return request<void>(
    `/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(id)}/share`,
    { method: 'DELETE' },
  )
}
