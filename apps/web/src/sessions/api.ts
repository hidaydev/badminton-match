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

/** One game as `GET /c/{slug}/sessions/{id}` returns it; sides hold player ids. */
export type SessionGame = {
  round: number
  court: number
  sideA: string[]
  sideB: string[]
  scoreA: number | null
  scoreB: number | null
  status: string
}

export type SessionParticipant = {
  playerId: string
  name: string
  absent: boolean
}

export type SessionDetail = SessionMeta & {
  startTime: string
  slotMinutes: number
  participants: SessionParticipant[]
  games: SessionGame[]
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

export function getSession(slug: string, id: string): Promise<SessionDetail> {
  return request<SessionDetail>(
    `/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(id)}`,
  )
}
