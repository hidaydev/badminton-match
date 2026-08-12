import type { CloudSnapshot, SessionMeta, PlayerSummary, PlayerStats } from './types'
import type { TournamentSnapshot } from '../utils/tournament'

// ── REST client terhadap majadu-api (Go backend) ─────────────────────────
// Base URL di-inject saat build oleh vite.config.ts (__API_BASE_URL__) —
// ditentukan dari branch (VERCEL_GIT_COMMIT_REF) atau override VITE_API_URL.
const BASE_URL: string = __API_BASE_URL__

export const TOURNAMENT_ID = 'tournament-2026-05-23-majadu'

export class RpcError extends Error {
  code: string | null
  constructor(message: string, code: string | null = null) {
    super(message)
    this.name = 'RpcError'
    this.code = code
  }
}

/** Check if an error is retryable (transient server/network errors) */
function isRetryableError(error: unknown): boolean {
  if (error instanceof RpcError) {
    const code = error.code
    return code === '429' || code === '503' || code === '500'
  }
  if (error instanceof DOMException && error.name === 'AbortError') return false
  if (error instanceof TypeError && error.message.includes('fetch')) return true
  return false
}

/** Check if an error is a timeout */
export function isTimeoutError(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError'
}

const RPC_TIMEOUT_MS = 30_000
const MAX_RETRIES = 3
const RETRY_BASE_DELAY_MS = 1_000

async function request<T>(
  method: string,
  path: string,
  body?: unknown,
  signal?: AbortSignal,
): Promise<T> {
  let lastError: unknown

  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    if (attempt > 0) {
      const delay = Math.min(RETRY_BASE_DELAY_MS * 2 ** (attempt - 1), 4_000)
      await new Promise(resolve => setTimeout(resolve, delay))
    }

    const controller = new AbortController()
    const timeoutId = setTimeout(() => controller.abort(), RPC_TIMEOUT_MS)
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
        const err = new RpcError(message, code)
        if (isRetryableError(err) && attempt < MAX_RETRIES) {
          lastError = err
          continue
        }
        throw err
      }

      if (res.status === 204) return undefined as T
      return await res.json() as T
    } catch (error) {
      if (signal?.aborted) throw error
      if (isRetryableError(error) && attempt < MAX_RETRIES) {
        lastError = error
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
      throw new RpcError('Invalid session snapshot received from server')
    }
    return data
  } catch (err) {
    if (err instanceof RpcError && err.code === 'not_found') return null
    throw err
  }
}

export async function publishSession(id: string, data: CloudSnapshot): Promise<CloudSnapshot> {
  const out = await request<CloudSnapshot>('PUT', `/sessions/${enc(id)}`, data)
  if (!isValidSnapshot(out)) {
    console.warn('[publishSession] response failed validation:', out)
    throw new RpcError('Invalid session snapshot received from server')
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
    throw new RpcError('Invalid session list received from server')
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

// Admin-only unlock — NOT wired to UI
export async function unlockSession(id: string): Promise<CloudSnapshot> {
  return await request<CloudSnapshot>('POST', `/sessions/${enc(id)}/unlock`)
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
    throw new RpcError('Invalid player stats received from server')
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

export async function getTournament(id: string): Promise<TournamentSnapshot | null> {
  try {
    return await request<TournamentSnapshot>('GET', `/tournaments/${enc(id)}`)
  } catch (err) {
    if (err instanceof RpcError && err.code === 'not_found') return null
    throw err
  }
}

export async function publishTournament(id: string, data: TournamentSnapshot): Promise<TournamentSnapshot> {
  return await request<TournamentSnapshot>('PUT', `/tournaments/${enc(id)}`, data)
}
