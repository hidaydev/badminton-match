import { request } from '../auth/api'

/** One game as a spectator sees it: names, not ids, and no roster behind it. */
export type SharedGame = {
  id: string
  round: number
  court: number
  sideA: string[]
  sideB: string[]
  scoreA: number | null
  scoreB: number | null
  status: string
}

/** `GET /s/{code}`: the only read that works without a session. */
export type SharedSession = {
  session: { id: string; title: string; date: string; status: string }
  community: { slug: string; name: string }
  games: SharedGame[]
}

export function getSharedSession(code: string): Promise<SharedSession> {
  return request<SharedSession>(`/s/${encodeURIComponent(code)}`)
}
