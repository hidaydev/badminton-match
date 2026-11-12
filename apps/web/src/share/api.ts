import { request } from '../auth/api'

export type SharedSet = { a: number; b: number }

/** One game as a spectator sees it: names, not ids, and no roster behind it. */
export type SharedGame = {
  id: string
  round: number
  court: number
  sideA: string[]
  sideB: string[]
  scoreA: number | null
  scoreB: number | null
  sets?: SharedSet[]
  setsWonA?: number
  setsWonB?: number
  winner?: 'A' | 'B' | null
  status: string
}

/** The format the session was played in; absent from an older payload. */
export type SharedScoring = {
  preset: string
  label: string
  gamesToWin: number
  pointsToWin: number
  winBy: number
  maxPoints: number
  deuceAt: number | null
  changeEndsAt: number | null
}

/** One row of the session board, already ordered by the server. */
export type SharedStanding = {
  name: string
  wins: number
  losses: number
  pointsFor: number
  pointsAgainst: number
  diff: number
}

/** `GET /s/{code}`: the only read that works without a session. */
export type SharedSession = {
  /** `startTime`/`slotMinutes` are absent from a payload from an older build. */
  session: {
    id: string
    title: string
    date: string
    status: string
    startTime?: string
    slotMinutes?: number
  }
  community: { slug: string; name: string }
  games: SharedGame[]
  /** The session's frozen format; absent from an older payload. */
  scoring?: SharedScoring | null
  /** Same tally the in-app session screen shows; absent from older payloads. */
  standings?: { items: SharedStanding[] } | null
}

export function getSharedSession(code: string): Promise<SharedSession> {
  return request<SharedSession>(`/s/${encodeURIComponent(code)}`)
}
