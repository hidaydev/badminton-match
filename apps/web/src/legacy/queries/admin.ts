// src/legacy/queries/admin.ts
// The restored admin screens still call v1-shaped admin paths. This module
// translates them to the v2 routes so the screens stay untouched.

import { request, getSession, communityApiPath } from './endpoints'

function withoutQuery(path: string): string {
  return path.split('?')[0]
}

export async function adminRequest<T = unknown>(
  method: string,
  path: string,
  body?: unknown,
): Promise<T> {
  const clean = withoutQuery(path)
  const payload = (body ?? {}) as Record<string, unknown>

  // Session administration.
  const unlock = /^\/sessions\/([^/]+)\/unlock$/.exec(clean)
  if (method === 'POST' && unlock) {
    const id = unlock[1]
    const snapshot = await getSession(id)
    const version = snapshot?.version ?? 0
    return request<T>('POST', communityApiPath(`/sessions/${encodeURIComponent(id)}/unlock`), undefined, undefined, {
      'If-Match': `"${version}"`,
    })
  }
  const sessionDelete = /^\/sessions\/([^/]+)\/delete$/.exec(clean)
  if (method === 'POST' && sessionDelete) {
    return request<T>('DELETE', communityApiPath(`/sessions/${encodeURIComponent(sessionDelete[1])}`))
  }
  const tournamentDelete = /^\/tournaments\/([^/]+)\/delete$/.exec(clean)
  if (method === 'POST' && tournamentDelete) {
    return request<T>('DELETE', communityApiPath(`/tournaments/${encodeURIComponent(tournamentDelete[1])}`))
  }

  // Players.
  if (method === 'POST' && clean === '/players') {
    return request<T>('POST', communityApiPath('/players'), {
      name: payload.name,
      tier: payload.tier,
    })
  }
  if (method === 'POST' && clean === '/players/merge') {
    const target = String(payload.targetPlayerId ?? '')
    const source = String(payload.sourcePlayerId ?? '')
    return request<T>('POST', communityApiPath(`/players/${encodeURIComponent(target)}/merge`), {
      sourcePlayerId: source,
    })
  }
  const playerTier = /^\/players\/([^/]+)\/tier$/.exec(clean)
  if (method === 'PATCH' && playerTier) {
    return request<T>('PATCH', communityApiPath(`/players/${encodeURIComponent(playerTier[1])}`), {
      tier: payload.tier,
    })
  }
  const playerName = /^\/players\/([^/]+)\/name$/.exec(clean)
  if (method === 'PATCH' && playerName) {
    return request<T>('PATCH', communityApiPath(`/players/${encodeURIComponent(playerName[1])}`), {
      name: payload.name,
    })
  }
  const playerDelete = /^\/players\/([^/]+)$/.exec(clean)
  if (method === 'DELETE' && playerDelete) {
    return request<T>('DELETE', communityApiPath(`/players/${encodeURIComponent(playerDelete[1])}`))
  }

  // Ratings.
  if (method === 'POST' && clean === '/ratings/rebuild-all') {
    return request<T>('POST', communityApiPath('/ratings/rebuild'))
  }
  const finalize = /^\/ratings\/sources\/([^/]+)\/finalize$/.exec(clean)
  if (method === 'POST' && finalize) {
    return request<T>('PATCH', communityApiPath(`/rating-sources/${encodeURIComponent(finalize[1])}`), {
      finalized: payload.finalized,
    })
  }
  if (method === 'POST' && clean === '/ratings/ingest-session') {
    return request<T>('POST', communityApiPath(`/sessions/${encodeURIComponent(String(payload.sessionId ?? ''))}/rating`))
  }
  if (method === 'POST' && clean === '/ratings/revert-session') {
    return request<T>('DELETE', communityApiPath(`/sessions/${encodeURIComponent(String(payload.sessionId ?? ''))}/rating`))
  }
  if (method === 'POST' && clean === '/ratings/ingest-tournament') {
    return request<T>('POST', communityApiPath(`/tournaments/${encodeURIComponent(String(payload.tournamentId ?? ''))}/rating`))
  }
  if (method === 'POST' && clean === '/ratings/revert-tournament') {
    return request<T>('DELETE', communityApiPath(`/tournaments/${encodeURIComponent(String(payload.tournamentId ?? ''))}/rating`))
  }

  // Anything not mapped is already a v2 path.
  return request<T>(method, communityApiPath(clean), body)
}
