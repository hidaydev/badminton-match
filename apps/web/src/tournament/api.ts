import { request } from '../auth/api'
import type { Tournament, TournamentMeta } from './types'

const base = (slug: string) => `/c/${encodeURIComponent(slug)}/tournaments`

export async function listTournaments(slug: string): Promise<TournamentMeta[]> {
  const body = await request<{ items: TournamentMeta[] }>(base(slug))
  return body.items
}

export function getTournament(slug: string, id: string): Promise<Tournament> {
  return request<Tournament>(`${base(slug)}/${encodeURIComponent(id)}`)
}

export function createTournament(
  slug: string,
  snapshot: Tournament,
): Promise<Tournament> {
  return request<Tournament>(base(slug), {
    method: 'POST',
    body: JSON.stringify(snapshot),
  })
}

/** Full replace. `version` is the `version` the caller last read (If-Match). */
export function replaceTournament(
  slug: string,
  id: string,
  snapshot: Tournament,
  version: number,
): Promise<Tournament> {
  return request<Tournament>(`${base(slug)}/${encodeURIComponent(id)}`, {
    method: 'PUT',
    body: JSON.stringify(snapshot),
    headers: { 'If-Match': `"${version}"` },
  })
}

export function deleteTournament(slug: string, id: string): Promise<void> {
  return request<void>(`${base(slug)}/${encodeURIComponent(id)}`, {
    method: 'DELETE',
  })
}

/** Classic: one match's two scores. Sending nulls clears the result. */
export function patchClassicMatch(
  slug: string,
  id: string,
  matchId: string,
  scores: { scoreA: number | null; scoreB: number | null },
  version: number,
): Promise<Tournament> {
  return request<Tournament>(
    `${base(slug)}/${encodeURIComponent(id)}/matches/${encodeURIComponent(matchId)}`,
    {
      method: 'PATCH',
      body: JSON.stringify(scores),
      headers: { 'If-Match': `"${version}"` },
    },
  )
}

/** Team: any partai scores and/or the three courts, for one team-match. */
export function patchTeamMatch(
  slug: string,
  id: string,
  matchId: string,
  patch: {
    courts?: [string, string, string]
    partai?: { scoreA: number | null; scoreB: number | null }[]
  },
  version: number,
): Promise<Tournament> {
  return request<Tournament>(
    `${base(slug)}/${encodeURIComponent(id)}/matches/${encodeURIComponent(matchId)}`,
    {
      method: 'PATCH',
      body: JSON.stringify(patch),
      headers: { 'If-Match': `"${version}"` },
    },
  )
}

/**
 * Signs the source off (or withdraws it) before a tournament can be rated.
 * `sourceId` is the tournament id; the API also accepts an event id.
 */
export async function finalizeSource(
  slug: string,
  sourceId: string,
  finalized: boolean,
): Promise<void> {
  await request(
    `/c/${encodeURIComponent(slug)}/rating-sources/${encodeURIComponent(sourceId)}`,
    { method: 'PATCH', body: JSON.stringify({ finalized }) },
  )
}

export type RatingIngest = { events: number; deltas: number }

/** Admin-only: one event per signed-off tournament. */
export function ingestTournamentRating(
  slug: string,
  id: string,
): Promise<RatingIngest> {
  return request<RatingIngest>(
    `${base(slug)}/${encodeURIComponent(id)}/rating`,
    { method: 'POST' },
  )
}

/** Admin-only: clears the event and rebuilds the derived state. */
export function revertTournamentRating(slug: string, id: string): Promise<void> {
  return request<void>(`${base(slug)}/${encodeURIComponent(id)}/rating`, {
    method: 'DELETE',
  })
}
