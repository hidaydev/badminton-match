import type { CloudSnapshot, SessionMeta, PlayerSummary, PlayerStats } from './types'
import type { TournamentSnapshot } from '../utils/tournament'
import type { AnyTournamentSnapshot, TeamTournamentSnapshot } from '../utils/teamTournament'
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

let adminToken = ''

/** Set admin token (Bearer) untuk semua request — dipanggil AdminContext. */
export function setAdminToken(token: string) {
  adminToken = token
}

export async function request<T>(
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
        headers: {
          ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
          ...(adminToken ? { Authorization: `Bearer ${adminToken}` } : {}),
        },
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

/** Validate bahwa response berbentuk TeamTournamentSnapshot (format 'team'). */
function isValidTeamTournamentSnapshot(data: unknown): data is TeamTournamentSnapshot {
  if (typeof data !== 'object' || data === null) return false
  const snap = data as Record<string, unknown>
  return (
    snap.format === 'team' &&
    typeof snap.name === 'string' &&
    Array.isArray(snap.teams) &&
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
    playerId?: string
    name: string
    gender: 'M' | 'F'
    tier: 1 | 2 | 3 | 4
    tierInduk?: string
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
  format: 'classic' | 'team'
}

export async function listTournaments(): Promise<TournamentMeta[]> {
  const rows = await request<Array<{ id: string; name: string; date: string; format?: string }>>('GET', '/tournaments')
  if (!Array.isArray(rows)) {
    console.warn('[listTournaments] response is not an array:', rows)
    throw new ApiError('Invalid tournament list received from server')
  }
  return rows.map((row) => ({
    id: row.id,
    name: row.name,
    date: row.date,
    format: row.format === 'team' ? 'team' : 'classic',
  }))
}

export async function getTournament(id: string): Promise<AnyTournamentSnapshot | null> {
  try {
    const data = await request<AnyTournamentSnapshot>('GET', `/tournaments/${enc(id)}`)
    if (data.format === 'team' ? !isValidTeamTournamentSnapshot(data) : !isValidTournamentSnapshot(data)) {
      console.warn('[getTournament] response failed validation:', data)
      throw new ApiError('Invalid tournament snapshot received from server')
    }
    return data
  } catch (err) {
    if (err instanceof ApiError && err.code === 'not_found') return null
    throw err
  }
}

export async function publishTournament(id: string, data: AnyTournamentSnapshot): Promise<AnyTournamentSnapshot> {
  return await request<AnyTournamentSnapshot>('PUT', `/tournaments/${enc(id)}`, data)
}

/** Create tournament (classic atau team — format di body). Kembalikan id baru
 * (dari header Location) + snapshot hasil create. Fetch langsung (bukan request)
 * karena mutasi tidak di-retry — dan butuh akses header. */
export async function createTournament(data: AnyTournamentSnapshot): Promise<{ id: string; snapshot: AnyTournamentSnapshot }> {
  const controller = new AbortController()
  const timeoutId = setTimeout(() => controller.abort(), API_TIMEOUT_MS)
  try {
    const res = await fetch(`${BASE_URL}/tournaments`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
      signal: controller.signal,
    })
    if (!res.ok) {
      let message = `${res.status} ${res.statusText}`
      let code: string | null = null
      try {
        const json = await res.json() as { error?: { message?: string; code?: string } }
        message = json.error?.message ?? message
        code = json.error?.code ?? null
      } catch { /* keep status text */ }
      throw new ApiError(message, code, res.status)
    }
    const snapshot = await res.json() as AnyTournamentSnapshot
    const loc = res.headers.get('Location') ?? ''
    const id = loc.split('/').pop() ?? ''
    return { id, snapshot }
  } finally {
    clearTimeout(timeoutId)
  }
}

// ── Rating (plan RATINGS_FRONTEND_PLAN.md §6.3) ───────────────────────────

export interface RatingLeaderboardRow {
  player_id: string
  name: string
  rating: number
  rd: number
  class: string
  class_derived: string
  class_display: string
  peak: number
  games: number
  trend: number
  provisional: boolean
}

export interface RatingHistoryRow {
  date: string
  title: string
  game_ref: string
  outcome: 'W' | 'L'
  delta: number
  expected: number
  movm: number
  score_a: number
  score_b: number
  new_rating: number
}

export interface RatingPlayer {
  name: string
  rating: number
  rd: number
  class: string
  class_derived: string
  class_display: string
  peak: number
  games: number
  wins: number
  losses: number
  history: RatingHistoryRow[]
}

export async function getRatingLeaderboard(
  active: boolean,
  limit: number,
  offset: number,
): Promise<{ total: number; rows: RatingLeaderboardRow[] }> {
  const q = `?active=${active}&limit=${limit}&offset=${offset}`
  const data = await request<{ total: number; rows: RatingLeaderboardRow[] }>('GET', `/ratings/leaderboard${q}`)
  return data ?? { total: 0, rows: [] }
}

export async function getRatingPlayer(playerId: string): Promise<RatingPlayer> {
  const data = await request<RatingPlayer | null>('GET', `/ratings/players/${enc(playerId)}`)
  if (!data) throw new Error('no data')
  return data
}


// ── Season (plan RATINGS_FRONTEND_PLAN Rev 3.7) ──────────────────────────

export interface RatingSeason {
  id: string
  name: string
  start_date: string
  end_date: string | null
  open: boolean
}

export interface SeasonStandingRow {
  name: string
  rating: number
  rd: number
  peak: number
  class: string
  class_display: string
  games: number
  wins: number
  losses: number
}

export async function getRatingSeasons(): Promise<RatingSeason[]> {
  const data = await request<{ seasons: RatingSeason[] }>('GET', `/ratings/seasons`)
  return data?.seasons ?? []
}

export async function getSeasonStandings(seasonId: string): Promise<SeasonStandingRow[]> {
  const data = await request<{ rows: SeasonStandingRow[] }>('GET', `/ratings/seasons/${enc(seasonId)}/standings`)
  return data?.rows ?? []
}
