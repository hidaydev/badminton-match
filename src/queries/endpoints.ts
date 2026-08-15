import type { CloudSnapshot, SessionMeta, PlayerSummary, PlayerStats } from './types'
import type { TournamentSnapshot } from '../utils/tournament'
import { parseRetryAfter, ApiError, shouldRetry } from './retry'

export { ApiError } from './retry'

// ── REST client terhadap majadu-api (Go backend) ─────────────────────────
// Base URL di-inject saat build oleh vite.config.ts (__API_BASE_URL__) —
// ditentukan dari branch (VERCEL_GIT_COMMIT_REF) atau override VITE_API_URL.
const BASE_URL: string = __API_BASE_URL__

const API_TIMEOUT_MS = 30_000
const MAX_RETRIES = 3
const RETRY_BASE_DELAY_MS = 1_000
const RETRY_MAX_DELAY_MS = 4_000

/** Exponential backoff (ms) sebelum retry setelah attempt `attempt` gagal. */
function backoffDelayMs(attempt: number): number {
  return Math.min(RETRY_BASE_DELAY_MS * 2 ** attempt, RETRY_MAX_DELAY_MS)
}

async function request<T>(
  method: string,
  path: string,
  body?: unknown,
  signal?: AbortSignal,
): Promise<T> {
  let lastError: unknown
  let retryDelayMs = 0

  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    if (attempt > 0) {
      await new Promise(resolve => setTimeout(resolve, retryDelayMs))
    }

    const controller = new AbortController()
    const timeoutId = setTimeout(() => controller.abort(), API_TIMEOUT_MS)
    const onAbort = () => controller.abort()
    signal?.addEventListener('abort', onAbort)

    try {
      const res = await fetch(`${BASE_URL}${path}`, {
        method,
        headers: body !== undefined ? { 'Content-Type': 'application/json' } : undefined,
        body: body !== undefined ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      })

      if (!res.ok) {
        let message = `${res.status} ${res.statusText}`
        let code: string | null = null
        try {
          const json = await res.json() as { error?: { message?: string; code?: string } }
          message = json.error?.message ?? message
          code = json.error?.code ?? null
        } catch {
          // keep HTTP status text
        }
        const err = new ApiError(message, code, res.status)
        if (shouldRetry(method, err, attempt, MAX_RETRIES)) {
          lastError = err
          // 429 (rate limit) → hormati header Retry-After kalau ada.
          const retryAfter = parseRetryAfter(res.headers.get('Retry-After'))
          retryDelayMs = retryAfter !== null ? retryAfter * 1_000 : backoffDelayMs(attempt)
          continue
        }
        throw err
      }

      if (res.status === 204) return undefined as T
      return await res.json() as T
    } catch (error) {
      if (signal?.aborted) throw error
      if (shouldRetry(method, error, attempt, MAX_RETRIES)) {
        lastError = error
        retryDelayMs = backoffDelayMs(attempt)
        continue
      }
      throw error
    } finally {
      clearTimeout(timeoutId)
      signal?.removeEventListener('abort', onAbort)
    }
  }

  throw lastError
}

// ── Validasi respons (sama seperti sebelumnya) ─────────────────────────────

/** Validate that a response has the shape of a CloudSnapshot */
function isValidSnapshot(data: unknown): data is CloudSnapshot {
  if (typeof data !== 'object' || data === null) return false
  const snap = data as Record<string, unknown>
  return (
    'session' in snap &&
    'players' in snap &&
    'schedule' in snap &&
    Array.isArray(snap.players) &&
    Array.isArray(snap.schedule)
  )
}

/** Validate that a response has the shape of TournamentSnapshot */
function isValidTournamentSnapshot(data: unknown): data is TournamentSnapshot {
  if (typeof data !== 'object' || data === null) return false
  const snap = data as Record<string, unknown>
  return (
    typeof snap.name === 'string' &&
    Array.isArray(snap.pairs) &&
    typeof snap.groups === 'object' &&
    snap.groups !== null &&
    !Array.isArray(snap.groups) &&
    Array.isArray(snap.matches)
  )
}

/** Validate that a response has the shape of PlayerStats */
function isValidPlayerStats(data: unknown): data is PlayerStats {
  if (typeof data !== 'object' || data === null) return false
  const stats = data as Record<string, unknown>
  return (
    typeof stats.name === 'string' &&
    typeof stats.gamesPlayed === 'number' &&
    typeof stats.wins === 'number' &&
    typeof stats.losses === 'number' &&
    typeof stats.pointsFor === 'number' &&
    typeof stats.pointsAgainst === 'number' &&
    Array.isArray(stats.sessions) &&
    Array.isArray(stats.topPartners) &&
    Array.isArray(stats.topOpponents)
  )
}

/** Empty tournamentStats — fallback kalau field tidak ada. */
const EMPTY_TOURNAMENT_STATS: PlayerStats['tournamentStats'] = {
  gamesPlayed: 0,
  wins: 0,
  losses: 0,
  tournaments: [],
  topPartners: [],
  topOpponents: [],
}

const enc = encodeURIComponent

// ── Sessions ──────────────────────────────────────────────────────────────

export async function getSession(id: string): Promise<CloudSnapshot | null> {
  try {
    const data = await request<CloudSnapshot>('GET', `/sessions/${enc(id)}`)
    if (!isValidSnapshot(data)) {
      console.warn('[getSession] response failed validation:', data)
      throw new ApiError('Invalid session snapshot received from server')
    }
    return data
  } catch (err) {
    if (err instanceof ApiError && err.code === 'not_found') return null
    throw err
  }
}

export async function publishSession(id: string, data: CloudSnapshot): Promise<CloudSnapshot> {
  const out = await request<CloudSnapshot>('PUT', `/sessions/${enc(id)}`, data)
  if (!isValidSnapshot(out)) {
    console.warn('[publishSession] response failed validation:', out)
    throw new ApiError('Invalid session snapshot received from server')
  }
  return out
}

export async function listSessions(): Promise<SessionMeta[]> {
  const rows = await request<Array<{
    id: string
    title: string
    date: string
    player_count: number
    total_games: number
    locked: boolean
  }>>('GET', '/sessions')

  if (!Array.isArray(rows)) {
    console.warn('[listSessions] response is not an array:', rows)
    throw new ApiError('Invalid session list received from server')
  }

  return rows.map((row) => ({
    id: row.id,
    title: row.title,
    date: row.date,
    playerCount: row.player_count,
    totalGames: row.total_games,
    locked: row.locked,
  }))
}

export async function deleteSession(lookup: string): Promise<{ deleted: boolean; sessionId: string }> {
  await request<void>('DELETE', `/sessions/${enc(lookup)}`)
  return { deleted: true, sessionId: lookup }
}

// ── Players ───────────────────────────────────────────────────────────────

export async function listPlayers(): Promise<PlayerSummary[]> {
  const rows = await request<Array<{
    name: string
    gender: 'M' | 'F'
    tier: 1 | 2 | 3 | 4
  }>>('GET', '/players')
  return rows
}

export async function getPlayerStats(name: string): Promise<PlayerStats> {
  const data = await request<PlayerStats | null>('GET', `/players/${enc(name)}/stats`)
  if (!data) throw new Error('no data')
  if (!isValidPlayerStats(data)) {
    console.warn('[getPlayerStats] response failed validation:', data)
    throw new ApiError('Invalid player stats received from server')
  }
  if (!data.tournamentStats) {
    data.tournamentStats = EMPTY_TOURNAMENT_STATS
  }
  return data
}

export async function registerPlayer(name: string, canonicalName?: string): Promise<{ playerId: string }> {
  return await request<{ playerId: string }>('POST', '/players', {
    name,
    canonicalName: canonicalName ?? undefined,
  })
}

// ── Tournaments ───────────────────────────────────────────────────────────

/** Metadata tournament untuk list (GET /tournaments). */
export interface TournamentMeta {
  id: string
  name: string
  date: string
}

export async function listTournaments(): Promise<TournamentMeta[]> {
  const rows = await request<Array<{ id: string; name: string; date: string }>>('GET', '/tournaments')
  if (!Array.isArray(rows)) {
    console.warn('[listTournaments] response is not an array:', rows)
    throw new ApiError('Invalid tournament list received from server')
  }
  return rows.map((row) => ({ id: row.id, name: row.name, date: row.date }))
}

export async function getTournament(id: string): Promise<TournamentSnapshot | null> {
  try {
    const data = await request<TournamentSnapshot>('GET', `/tournaments/${enc(id)}`)
    if (!isValidTournamentSnapshot(data)) {
      console.warn('[getTournament] response failed validation:', data)
      throw new ApiError('Invalid tournament snapshot received from server')
    }
    return data
  } catch (err) {
    if (err instanceof ApiError && err.code === 'not_found') return null
    throw err
  }
}

export async function publishTournament(id: string, data: TournamentSnapshot): Promise<TournamentSnapshot> {
  return await request<TournamentSnapshot>('PUT', `/tournaments/${enc(id)}`, data)
}
