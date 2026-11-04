import { request } from '../auth/api'

/** One row of `GET /c/{slug}/sessions`. */
export type SessionMeta = {
  id: string
  title: string
  date: string
  status: string
  version: number
}

/** One player's tally in `GET /c/{slug}/sessions/{id}/standings`. */
export type SessionStanding = {
  playerId: string
  name: string
  wins: number
  losses: number
  pointsFor: number
  pointsAgainst: number
  diff: number
}

export type SessionBoard = {
  sessionId: string
  title: string
  date: string
  items: SessionStanding[]
}

export async function listSessions(slug: string): Promise<SessionMeta[]> {
  const body = await request<{ items: SessionMeta[] }>(
    `/c/${encodeURIComponent(slug)}/sessions`,
  )
  return body.items
}

export function getSessionStandings(slug: string, id: string): Promise<SessionBoard> {
  return request<SessionBoard>(
    `/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(id)}/standings`,
  )
}
