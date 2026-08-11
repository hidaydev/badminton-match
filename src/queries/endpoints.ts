import type { CloudSnapshot, SessionMeta, PlayerSummary, PlayerStats } from './types'
import type { TournamentSnapshot } from '../utils/tournament'

export const TOURNAMENT_ID = 'tournament-2026-05-23-majadu'

function supabaseUrl(): string {
  const url = import.meta.env.VITE_SUPABASE_URL as string
  if (!url) throw new Error('VITE_SUPABASE_URL is not set')
  return url
}

function supabaseKey(): string {
  const key = import.meta.env.VITE_SUPABASE_KEY as string
  if (!key) throw new Error('VITE_SUPABASE_KEY is not set')
  return key
}

function rpcUrl(name: string): string {
  return `${supabaseUrl()}/rest/v1/rpc/${name}`
}

function rpcHeaders(): HeadersInit {
  const key = supabaseKey()
  return {
    apikey: key,
    Authorization: `Bearer ${key}`,
    'Content-Type': 'application/json',
    Accept: 'application/json',
    // Skema backend per environment (bm = prod/Supabase, bm_dev = dev/staging/VPS).
    // Di-inject saat build oleh vite.config.ts (__BACKEND_PROFILE__).
    'Accept-Profile': __BACKEND_PROFILE__,
    'Content-Profile': __BACKEND_PROFILE__,
  }
}

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
    Array.isArray(stats.topOpponents) &&
    // V2: tournamentStats wajib — kalau absen (server schema lama), fallback di
    // getPlayerStats supaya UI tidak crash.
    (stats.tournamentStats === undefined || typeof stats.tournamentStats === 'object')
  )
}

/** Empty tournamentStats — dipakai sebagai fallback kalau server schema lama. */
const EMPTY_TOURNAMENT_STATS: PlayerStats['tournamentStats'] = {
  gamesPlayed: 0,
  wins: 0,
  losses: 0,
  tournaments: [],
  topPartners: [],
  topOpponents: [],
}

const RPC_TIMEOUT_MS = 30_000
const MAX_RETRIES = 3
const RETRY_BASE_DELAY_MS = 1_000

async function callRpc<T>(
  name: string,
  body: Record<string, unknown>,
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

    // Link external signal to internal controller
    const onAbort = () => controller.abort()
    signal?.addEventListener('abort', onAbort)

    try {
      const res = await fetch(rpcUrl(name), {
        method: 'POST',
        headers: rpcHeaders(),
        body: JSON.stringify(body),
        signal: controller.signal,
      })

      if (!res.ok) {
        let detail = `${res.status} ${res.statusText}`
        let code: string | null = null
        try {
          const json = await res.json() as { message?: string; error?: string; hint?: string; code?: string }
          detail = json.message ?? json.error ?? json.hint ?? detail
          code = json.code ?? null
        } catch {
          // keep HTTP detail
        }
        const err = new RpcError(detail, code)
        if (isRetryableError(err) && attempt < MAX_RETRIES) {
          lastError = err
          continue
        }
        throw err
      }

      if (res.status === 204) return undefined as T
      return await res.json() as T
    } catch (error) {
      // Don't retry if the external signal was aborted
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

export async function getSession(id: string): Promise<CloudSnapshot | null> {
  const data = await callRpc<CloudSnapshot | null>('get_session', { p_id: id })
  if (data !== null && !isValidSnapshot(data)) {
    console.warn('[getSession] response failed validation:', data)
    throw new RpcError('Invalid session snapshot received from server')
  }
  return data
}

export async function publishSession(id: string, data: CloudSnapshot): Promise<CloudSnapshot> {
  return await callRpc<CloudSnapshot>('publish_session', { p_id: id, p_snapshot: data })
}

export async function listSessions(): Promise<SessionMeta[]> {
  const rows = await callRpc<Array<{
    id: string
    title: string
    date: string
    player_count: number
    total_games: number
    locked: boolean
  }>>('list_sessions', {})

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

export async function listPlayers(): Promise<PlayerSummary[]> {
  const rows = await callRpc<Array<{
    name: string
    gender: 'M' | 'F'
    tier: 1 | 2 | 3 | 4
  }>>('list_players', {})
  return rows
}

export async function getPlayerStats(name: string): Promise<PlayerStats> {
  const data = await callRpc<PlayerStats | null>('get_player_stats', { p_name: name })
  if (!data) throw new Error('no data')
  if (!isValidPlayerStats(data)) {
    console.warn('[getPlayerStats] response failed validation:', data)
    throw new RpcError('Invalid player stats received from server')
  }
  // V2: kalau server schema lama (belum ada tournamentStats), kasih default —
  // UI tahan schema-mismatch saat dev/prod beda versi (risiko yang dikelola
  // __BACKEND_PROFILE__).
  if (!data.tournamentStats) {
    data.tournamentStats = EMPTY_TOURNAMENT_STATS
  }
  return data
}

export async function registerPlayer(name: string, canonicalName?: string): Promise<{ playerId: string }> {
  const result = await callRpc<string>('register_player', {
    p_name: name,
    p_canonical_name: canonicalName ?? null,
  })
  return { playerId: result }
}

export async function deleteSession(lookup: string): Promise<{ deleted: boolean; sessionId: string }> {
  return await callRpc<{ deleted: boolean; sessionId: string }>('delete_session', { p_lookup: lookup })
}

// Admin-only unlock RPC — NOT wired to UI
export async function unlockSession(id: string): Promise<CloudSnapshot> {
  return await callRpc<CloudSnapshot>('unlock_session', { p_id: id })
}

export async function getTournament(id: string): Promise<TournamentSnapshot | null> {
  return await callRpc<TournamentSnapshot | null>('get_tournament', { p_id: id })
}

export async function publishTournament(id: string, data: TournamentSnapshot): Promise<TournamentSnapshot> {
  return await callRpc<TournamentSnapshot>('publish_tournament', { p_id: id, p_snapshot: data })
}
