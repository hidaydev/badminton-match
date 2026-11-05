// src/legacy/queries/endpoints.ts
// Adapter between the restored v1 screens and the v2 HTTP API. The v1 tree
// still speaks `CloudSnapshot` and slug-less paths; everything is translated
// here so the screens themselves stay untouched.
//
// The community slug comes from the route (`/c/:slug`). `setCommunitySlug` is
// called once by the legacy shell before any screen mounts.

import { toPlayerId, toTimeString } from '../types'
import type { GameKey, Gender, Player, Tier } from '../types'
import type { CloudSnapshot, PlayerSummary, PlayerStats, SessionMeta } from './types'
import type { AnyTournamentSnapshot } from '../utils/teamTournament'
import { parseRetryAfter, ApiError, shouldRetry } from './retry'
import { isClientOutdated, reportClientOutdated, reportSessionExpired } from '../../api/errors'

export { ApiError } from './retry'

/** Same-origin `/api` path; the dev proxy and the production rewrite both strip it. */
export const BASE_URL: string = import.meta.env.VITE_API_BASE || '/api'

const API_VERSION = '2'
const API_TIMEOUT_MS = 30_000
const MAX_RETRIES = 3
const RETRY_BASE_DELAY_MS = 1_000
const RETRY_MAX_DELAY_MS = 4_000

let communitySlug = ''

/** The legacy shell calls this before rendering community screens. */
export function setCommunitySlug(slug: string) {
  if (slug === communitySlug) return
  communitySlug = slug
  // Player names/ids belong to the community that was active when they were
  // read; keeping them would join the wrong gender/tier onto the next one.
  playerCache = null
  playerCacheSlug = ''
  playerIdByName.clear()
}

/**
 * The slug the shell last set; the socket path and the persisted draft need it.
 * Request paths and cache keys use `activeCommunitySlug` instead.
 */
export function currentCommunitySlug(): string {
  return communitySlug
}

/**
 * The community the browser is actually showing. The pathname wins over the
 * module variable: React may render a community shell and throw the render
 * away, so a request or cache key built afterwards must not inherit that
 * discarded slug (FE-40). Tests and non-community paths fall back to the value
 * the shell published.
 */
export function activeCommunitySlug(): string {
  const match = /^\/c\/([^/]+)/.exec(window.location.pathname)
  return match ? decodeURIComponent(match[1]) : communitySlug
}

/** A one-use ticket for the session socket; it expires in seconds. */
export async function issueSessionTicket(
  sessionId: string,
  signal?: AbortSignal,
): Promise<{ ticket: string; expiresIn: number }> {
  return await request('POST',
    communityPath(`/sessions/${enc(sessionId)}/ws-ticket`), undefined, signal)
}

function communityPath(path: string): string {
  const slug = activeCommunitySlug()
  if (slug === '') {
    throw new ApiError('community slug is not set')
  }
  return `/c/${encodeURIComponent(slug)}${path}`
}

/** v2 path for callers that build their own request (admin screens). */
export function communityApiPath(path: string): string {
  return communityPath(path)
}

function backoffDelayMs(attempt: number): number {
  return Math.min(RETRY_BASE_DELAY_MS * 2 ** attempt, RETRY_MAX_DELAY_MS)
}

// Kept for the legacy AdminContext import surface. Admin access now follows
// membership role, so no bearer token is ever sent.
export async function verifyAdminToken(_token: string): Promise<boolean> {
  void _token
  return false
}

export function setAdminToken(_token: string) {
  void _token
}

export function request<T>(
  method: string,
  path: string,
  body?: unknown,
  signal?: AbortSignal,
  extraHeaders?: Record<string, string>,
): Promise<T>
export function request<T>(
  method: string,
  path: string,
  body: unknown,
  signal: AbortSignal | undefined,
  extraHeaders: Record<string, string> | undefined,
  includeHeaders: true,
): Promise<{ data: T; headers: Headers }>
export async function request<T>(
  method: string,
  path: string,
  body?: unknown,
  signal?: AbortSignal,
  extraHeaders?: Record<string, string>,
  includeHeaders?: boolean,
): Promise<T | { data: T; headers: Headers }> {
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
        credentials: 'include',
        headers: {
          'X-API-Version': API_VERSION,
          ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
          ...(extraHeaders ?? {}),
        },
        body: body !== undefined ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      })

      if (!res.ok) {
        let message = `${res.status} ${res.statusText}`
        let code: string | null = null
        try {
          const json = await res.json() as { detail?: string; message?: string; code?: string }
          message = json.detail ?? json.message ?? message
          code = json.code ?? null
        } catch {
          // keep HTTP status text
        }
        const err = new ApiError(message, code, res.status)
        // A 410 means the contract moved and a 401 means the cookie is gone.
        // Both are shell-level states, so signal them for every legacy caller
        // instead of letting ~90% of traffic render a generic "Failed to load".
        if (isClientOutdated(err)) reportClientOutdated()
        if (res.status === 401) reportSessionExpired()
        if (shouldRetry(method, err, attempt, MAX_RETRIES)) {
          lastError = err
          const retryAfter = parseRetryAfter(res.headers.get('Retry-After'))
          retryDelayMs = retryAfter !== null ? retryAfter * 1_000 : backoffDelayMs(attempt)
          continue
        }
        throw err
      }

      if (res.status === 204) {
        return includeHeaders ? { data: undefined as T, headers: res.headers } : (undefined as T)
      }
      const data = await res.json() as T
      return includeHeaders ? { data, headers: res.headers } : data
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

const enc = encodeURIComponent

function makeIdempotencyKey(): string {
  try {
    return crypto.randomUUID()
  } catch {
    return `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`
  }
}

function ifMatch(version: number | undefined): Record<string, string> {
  return version == null ? {} : { 'If-Match': `"${version}"` }
}

function isNotFound(error: unknown): boolean {
  return error instanceof ApiError && (error.status === 404 || error.code === 'NOT_FOUND')
}

// ── Player cache ──────────────────────────────────────────────────────────
// Session reads do not carry gender/tier, so the snapshot joins this cache.
// `listPlayers` fills it; a session load fills it once if it is still empty.
// The rows are stamped with the community they came from: a stale entry must
// never join one community's gender/tier onto another's session.

let playerCache: PlayerSummary[] | null = null
let playerCacheSlug = ''
/** name → id learned from a stats read, so a second read is not a lookup. */
const playerIdByName = new Map<string, string>()

function cachedPlayers(): PlayerSummary[] | null {
  return playerCacheSlug === activeCommunitySlug() ? playerCache : null
}

const TIER_NUMBER: Record<string, Tier> = {
  D: 1,
  'D+': 2,
  C: 3,
  'C+': 4,
  B: 5,
  'B+': 6,
  A: 7,
  'A+': 8,
}

function tierNumber(tier: string | null): Tier {
  return tier === null ? 2 : (TIER_NUMBER[tier.toUpperCase()] ?? 2)
}

type V2Player = {
  id: string
  name: string
  gender: string | null
  tier: string | null
  userId: string | null
  createdAt: string
  updatedAt: string
  aliases?: string[]
}

function toPlayerSummary(player: V2Player): PlayerSummary {
  return {
    playerId: player.id,
    name: player.name,
    gender: player.gender === 'F' ? 'F' : 'M',
    tier: tierNumber(player.tier),
    tierInduk: player.tier ?? undefined,
  }
}

// ── Session mapping ───────────────────────────────────────────────────────

// Last ETag seen per `community:session`, so a poll can ask "still the same?"
// instead of downloading the snapshot again. Kept per community because the
// same id under another community is a different resource.
const sessionEtags = new Map<string, string>()

type V2Game = {
  round: number
  court: number
  sideA: string[]
  sideB: string[]
  scoreA: number | null
  scoreB: number | null
  status: string
}

type V2SessionDetail = {
  id: string
  title: string
  date: string
  startTime: string
  slotMinutes: number
  status: string
  version: number
  participants: Array<{ playerId: string; name: string; absent: boolean }>
  games: V2Game[]
  skippedPlayers?: Record<string, string[]>
}

function timeToMinutes(time: string): number {
  const [hours, minutes] = time.split(':').map((part) => Number.parseInt(part, 10))
  return (hours || 0) * 60 + (minutes || 0)
}

function minutesToTime(total: number): string {
  const normalized = Math.max(0, total)
  const hours = Math.floor(normalized / 60) % 24
  const minutes = normalized % 60
  return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}`
}

function gameKey(game: V2Game): GameKey {
  return `${game.round}-${game.court}` as GameKey
}

function sessionPlayerMap(participants: V2SessionDetail['participants']): Map<string, Player> {
  const cached = new Map((cachedPlayers() ?? []).map((player) => [player.playerId ?? '', player]))
  const out = new Map<string, Player>()
  for (const participant of participants) {
    const known = cached.get(participant.playerId)
    out.set(participant.playerId, {
      id: toPlayerId(participant.playerId),
      name: participant.name,
      gender: (known?.gender ?? 'M') as Gender,
      tier: (known?.tier ?? 2) as Tier,
    })
  }
  return out
}

function toCloudSnapshot(detail: V2SessionDetail): CloudSnapshot {
  const playerMap = sessionPlayerMap(detail.participants)
  const courts = detail.games.reduce((max, game) => Math.max(max, game.court + 1), 1)
  const rounds = detail.games.reduce((max, game) => Math.max(max, game.round + 1), 1)
  const end = minutesToTime(timeToMinutes(detail.startTime) + detail.slotMinutes * rounds)
  const courtTimes = Array.from({ length: courts }, () => ({
    start: toTimeString(detail.startTime),
    end: toTimeString(end),
  }))

  const playedGames: string[] = []
  const gameScores: CloudSnapshot['gameScores'] = {}
  const skippedPlayers: Record<string, string[]> = {}

  for (const game of detail.games) {
    const key = gameKey(game)
    if (game.status === 'played') playedGames.push(key)
    if (game.scoreA !== null && game.scoreB !== null) {
      gameScores[key] = { a: game.scoreA, b: game.scoreB }
    }
    if (game.status === 'cancelled') {
      skippedPlayers[key] = [...game.sideA, ...game.sideB]
    }
    const perPlayer = detail.skippedPlayers?.[key]
    if (perPlayer?.length) {
      skippedPlayers[key] = [...new Set([...(skippedPlayers[key] ?? []), ...perPlayer])]
    }
  }

  return {
    version: detail.version,
    session: {
      title: detail.title,
      date: detail.date,
      courts,
      sessionStart: toTimeString(detail.startTime),
      slotMinutes: detail.slotMinutes,
      courtTimes,
      playerCount: detail.participants.length,
      courtNames: [],
      locked: detail.status === 'locked',
    },
    players: detail.participants.map((participant) => playerMap.get(participant.playerId)!).filter(Boolean),
    fixMatches: [],
    schedule: detail.games.map((game) => ({
      slot: game.round,
      court: game.court,
      teamA: [game.sideA[0] ?? '', game.sideA[1] ?? ''] as never,
      teamB: [game.sideB[0] ?? '', game.sideB[1] ?? ''] as never,
    })),
    playedGames,
    gameScores,
    absentPlayers: detail.participants.filter((participant) => participant.absent).map((p) => p.playerId),
    skippedPlayers,
  }
}

const NOT_MODIFIED = Symbol('not-modified')

// `etag` is only sent by the polling read. Every other caller wants the body, so
// asking "still the same?" there would only turn a 200 into a rejected promise.
async function readSessionDetail(
  id: string,
  signal: AbortSignal | undefined,
  etag: string | undefined,
): Promise<V2SessionDetail | null | typeof NOT_MODIFIED> {
  const key = `${activeCommunitySlug()}:${id}`
  try {
    const result = (await request<V2SessionDetail>(
      'GET',
      communityPath(`/sessions/${enc(id)}`),
      undefined,
      signal,
      etag ? { 'If-None-Match': etag } : undefined,
      true,
    )) as { data: V2SessionDetail; headers: Headers }
    const next = result.headers.get('ETag')
    if (next) sessionEtags.set(key, next)
    return result.data
  } catch (error) {
    if (error instanceof ApiError && error.status === 304) return NOT_MODIFIED
    if (isNotFound(error)) return null
    throw error
  }
}

async function fetchSessionDetail(id: string, signal?: AbortSignal): Promise<V2SessionDetail | null> {
  const detail = await readSessionDetail(id, signal, undefined)
  if (detail === null) return null
  if (detail === NOT_MODIFIED) {
    throw new ApiError('unexpected 304 from a read without If-None-Match', 'NOT_MODIFIED', 304)
  }
  return detail
}

async function sessionSnapshot(id: string): Promise<CloudSnapshot> {
  const detail = await fetchSessionDetail(id)
  if (detail === null) throw new ApiError('session not found', 'NOT_FOUND', 404)
  return toCloudSnapshot(detail)
}

// ── Sessions ──────────────────────────────────────────────────────────────

export async function getSession(
  id: string,
  signal?: AbortSignal,
  previous?: () => CloudSnapshot | null | undefined,
): Promise<CloudSnapshot | null> {
  // The player table is only needed to join gender/tier onto the snapshot, so
  // it is read alongside the session instead of before it.
  // Polling re-reads the same session every few seconds; the API answers 304
  // when nothing changed, and the cached snapshot is kept.
  const detailPromise = readSessionDetail(
    id,
    signal,
    previous === undefined ? undefined : sessionEtags.get(`${activeCommunitySlug()}:${id}`),
  )
  if (cachedPlayers() === null) {
    try {
      await listPlayers(signal)
    } catch {
      playerCache = []
      playerCacheSlug = activeCommunitySlug()
    }
  }
  const detail = await detailPromise
  if (detail === NOT_MODIFIED) {
    // The cached snapshot is still current. A 304 without a cached value would
    // be a stale ETag with nothing to show, so that one read goes unconditioned.
    const cached = previous?.()
    if (cached != null) return cached
    const fresh = await fetchSessionDetail(id, signal)
    if (fresh === null) return null
    return toCloudSnapshot(fresh)
  }
  if (detail === null) return null
  return toCloudSnapshot(detail)
}

/**
 * The wizard keeps its own short player ids; v2 schedules store community
 * player UUIDs. Resolve every name once and return local -> server id.
 */
async function resolveSnapshotPlayers(players: Player[]): Promise<Map<string, string>> {
  const ids = new Map<string, string>()
  for (const player of players) {
    if (ids.has(player.id)) continue
    try {
      ids.set(player.id, await resolvePlayerId(player.name))
    } catch (error) {
      if (!isNotFound(error)) throw error
      const created = await registerPlayer(player.name, undefined, player.gender)
      ids.set(player.id, created.playerId)
    }
  }
  return ids
}

/**
 * Full-snapshot save kept for the two legacy callers (share button and the
 * debounced wizard publish). v2 has no snapshot write, so the pieces are
 * replayed in order and the resulting session is read back.
 *
 * If-Match starts from the version carried by `data` — the snapshot the caller
 * holds — not from the record read below. Reading the session is only there to
 * prove it still exists and to diff the games; taking its version instead would
 * mean two writers with stale snapshots both "win", and stale scores would be
 * re-PATCHed over a newer state.
 */
export async function publishSession(id: string, data: CloudSnapshot): Promise<CloudSnapshot> {
  const current = await fetchSessionDetail(id)
  if (current === null) throw new ApiError('session not found', 'NOT_FOUND', 404)
  const playerIds = await resolveSnapshotPlayers(data.players)
  const serverId = (localId: string): string => playerIds.get(localId) ?? localId

  let version = data.version ?? current.version
  const patchRecord = await request<{ version?: number }>(
    'PATCH',
    communityPath(`/sessions/${enc(id)}`),
    {
      title: data.session.title,
      date: data.session.date,
      startTime: data.session.sessionStart,
      slotMinutes: data.session.slotMinutes,
    },
    undefined,
    { ...ifMatch(version), 'Idempotency-Key': makeIdempotencyKey() },
  )
  version = patchRecord.version ?? version

  const schedule = data.schedule.map((slot) => ({
    round: slot.slot,
    court: slot.court,
    sideA: [slot.teamA[0], slot.teamA[1]].map(String).filter(Boolean).map(serverId),
    sideB: [slot.teamB[0], slot.teamB[1]].map(String).filter(Boolean).map(serverId),
  }))

  const scheduled = await request<{ version?: number }>(
    'PUT',
    communityPath(`/sessions/${enc(id)}/schedule`),
    { games: schedule },
    undefined,
    ifMatch(version),
  )
  version = scheduled.version ?? version

  // v2 keeps the score on the game row, so publish only the games whose
  // server state differs from the snapshot.
  const persisted = await fetchSessionDetail(id)
  const serverGames = new Map(
    (persisted?.games ?? []).map((game) => [gameKey(game), game]),
  )
  for (const slot of data.schedule) {
    const key = `${slot.slot}-${slot.court}` as GameKey
    const server = serverGames.get(key)
    const score = data.gameScores[key]
    const wantPlayed = data.playedGames.includes(key)
    let body: Record<string, unknown> | null = null
    if (score !== undefined) {
      if (server?.scoreA !== score.a || server?.scoreB !== score.b) {
        body = { scoreA: score.a, scoreB: score.b }
      }
    } else if (server !== undefined) {
      if (wantPlayed && (server.status !== 'played' || server.scoreA !== null)) {
        body = { played: true }
      } else if (!wantPlayed && (server.status !== 'scheduled' || server.scoreA !== null)) {
        body = { played: false }
      }
    }
    if (body === null) continue
    const record = await request<{ version?: number }>(
      'PATCH',
      communityPath(`/sessions/${enc(id)}/games/${enc(key)}`),
      body,
      undefined,
      ifMatch(version),
    )
    version = record.version ?? version
  }

  if (data.absentPlayers !== undefined) {
    const record = await request<{ version?: number }>(
      'PATCH',
      communityPath(`/sessions/${enc(id)}/absent`),
      { playerIds: data.absentPlayers.map(serverId) },
      undefined,
      ifMatch(version),
    )
    version = record.version ?? version
  }

  // `session.locked` in the v1 store means "setup finished", not "server
  // locked": mapping it to v2 lock would make every later score write fail.
  return sessionSnapshot(id)
}

export async function patchGameScore(
  id: string,
  key: string,
  a: number,
  b: number,
  expectedVersion: number,
): Promise<CloudSnapshot> {
  await request<unknown>('PATCH', communityPath(`/sessions/${enc(id)}/games/${enc(key)}`), {
    scoreA: a,
    scoreB: b,
  }, undefined, ifMatch(expectedVersion))
  return sessionSnapshot(id)
}

export async function patchGamePlayed(
  id: string,
  key: string,
  isPlayed: boolean,
  expectedVersion: number,
): Promise<CloudSnapshot> {
  await request<unknown>('PATCH', communityPath(`/sessions/${enc(id)}/games/${enc(key)}`), {
    played: isPlayed,
  }, undefined, ifMatch(expectedVersion))
  return sessionSnapshot(id)
}

export async function patchAbsentPlayers(
  id: string,
  playerIds: string[],
  expectedVersion: number,
): Promise<CloudSnapshot> {
  await request<unknown>('PATCH', communityPath(`/sessions/${enc(id)}/absent`), {
    playerIds,
  }, undefined, ifMatch(expectedVersion))
  return sessionSnapshot(id)
}

/**
 * v2 stores a skip per player: the game stays in the schedule and only the
 * named players are left out of that game's tally.
 */
export async function patchGameSkipped(
  id: string,
  key: string,
  playerIds: string[],
  expectedVersion: number,
): Promise<CloudSnapshot> {
  await request<unknown>(
    'PATCH',
    communityPath(`/sessions/${enc(id)}/games/${enc(key)}/skip`),
    { playerIds },
    undefined,
    ifMatch(expectedVersion),
  )
  return sessionSnapshot(id)
}

export interface GranularSwapTarget {
  slot: number
  court: number
  team?: 'A' | 'B'
  position?: 0 | 1
}

export async function swapMembers(
  id: string,
  type: 'player' | 'team' | 'slot',
  a: GranularSwapTarget,
  b: GranularSwapTarget,
  expectedVersion: number,
): Promise<CloudSnapshot> {
  await request<unknown>('POST', communityPath(`/sessions/${enc(id)}/swap`), {
    type,
    a,
    b,
  }, undefined, { ...ifMatch(expectedVersion), 'Idempotency-Key': makeIdempotencyKey() })
  return sessionSnapshot(id)
}

export interface SessionPage {
  items: SessionMeta[]
  total: number
  nextOffset: number | null
}

export async function listSessions(options?: {
  date?: string
  q?: string
  limit?: number
  offset?: number
  signal?: AbortSignal
}): Promise<SessionPage> {
  // The server pages and filters, so a search covers the whole history instead
  // of whatever page happened to be loaded.
  const params = new URLSearchParams()
  if (options?.limit !== undefined) params.set('limit', String(options.limit))
  if (options?.offset !== undefined && options.offset > 0) params.set('offset', String(options.offset))
  if (options?.date) params.set('date', options.date)
  if (options?.q?.trim()) params.set('q', options.q.trim())
  const query = params.size > 0 ? `?${params.toString()}` : ''

  const body = await request<{ items: Array<{
    id: string
    title: string
    date: string
    status: string
    version: number
    playerCount?: number
    totalGames?: number
  }>, total?: number, nextCursor?: string }>(
    'GET', communityPath('/sessions') + query, undefined, options?.signal)

  if (!Array.isArray(body?.items)) {
    console.warn('[listSessions] response is not an array:', body)
    throw new ApiError('Invalid session list received from server')
  }

  const items = body.items.map((row) => ({
    id: row.id,
    title: row.title,
    date: row.date,
    playerCount: row.playerCount ?? 0,
    totalGames: row.totalGames ?? 0,
    locked: row.status === 'locked',
  }))

  const total = typeof body.total === 'number' ? body.total : items.length
  const nextOffset = Number(body.nextCursor)
  return {
    items,
    total,
    nextOffset: Number.isFinite(nextOffset) && nextOffset > (options?.offset ?? 0)
      ? nextOffset
      : null,
  }
}

/** Finishing a session approves it and rates it; reopening withdraws the rating. */
export async function setSessionLock(
  sessionId: string,
  locked: boolean,
  expectedVersion: number,
): Promise<void> {
  await request<unknown>('POST',
    communityPath(`/sessions/${enc(sessionId)}/${locked ? 'lock' : 'unlock'}`),
    undefined, undefined, ifMatch(expectedVersion))
}

export async function deleteSession(lookup: string): Promise<{ deleted: boolean; sessionId: string }> {
  await request<void>('DELETE', communityPath(`/sessions/${enc(lookup)}`))
  return { deleted: true, sessionId: lookup }
}

export async function createSession(input: {
  title: string
  date: string
  startTime: string
  slotMinutes: number
}): Promise<{ id: string }> {
  return request<{ id: string }>(
    'POST',
    communityPath('/sessions'),
    input,
    undefined,
    { 'Idempotency-Key': makeIdempotencyKey() },
  )
}

/** The live code, or null when the session has no link yet. */
export async function getSessionShareCode(id: string): Promise<string | null> {
  try {
    const live = await request<{ code: string }>(
      'GET',
      communityPath(`/sessions/${enc(id)}/share`),
    )
    return live.code || null
  } catch (error) {
    if (isNotFound(error)) return null
    throw error
  }
}

/** Reuses the live code when one exists; a new code only replaces the old one. */
export async function ensureSessionShareLink(id: string): Promise<string> {
  const live = await getSessionShareCode(id)
  if (live !== null) return live
  const created = await request<{ code: string }>(
    'POST',
    communityPath(`/sessions/${enc(id)}/share`),
    undefined,
    undefined,
    { 'Idempotency-Key': makeIdempotencyKey() },
  )
  return created.code
}

// ── Players ───────────────────────────────────────────────────────────────

export async function listPlayers(signal?: AbortSignal): Promise<PlayerSummary[]> {
  const body = await request<{ items: V2Player[] }>(
    'GET',
    communityPath('/players?limit=1000'),
    undefined,
    signal,
  )
  const rows = body?.items ?? []
  const summaries = rows.map(toPlayerSummary)
  playerCache = summaries
  playerCacheSlug = activeCommunitySlug()
  return summaries
}

async function resolvePlayerId(nameOrId: string, signal?: AbortSignal): Promise<string> {
  if (/^[0-9a-f-]{36}$/i.test(nameOrId)) return nameOrId
  const cached = playerCache?.find((player) => player.name.toLowerCase() === nameOrId.toLowerCase())
  if (cached?.playerId) return cached.playerId
  const body = await request<{ items: V2Player[] }>(
    'GET',
    communityPath(`/players?limit=100&q=${enc(nameOrId)}`),
    undefined,
    signal,
  )
  const match = body?.items.find((player) => player.name.toLowerCase() === nameOrId.toLowerCase())
  if (match === undefined) throw new ApiError('player not found', 'NOT_FOUND', 404)
  return match.id
}

export type V2PlayerStats = {
  playerId: string
  name: string
  tier: string | null
  gender: string | null
  points: number
  games: number
  wins: number
  losses: number
  history?: Array<{
    date: string
    title: string
    gameRef: string
    outcome: 'W' | 'L'
    scoreA: number
    scoreB: number
    teammates: string[]
    opponents: string[]
  }>
  sessions?: PlayerStats['sessions']
  topPartners?: PlayerStats['topPartners']
  topOpponents?: PlayerStats['topOpponents']
  tournamentStats?: PlayerStats['tournamentStats']
}

async function fetchPlayerStats(playerId: string, signal?: AbortSignal): Promise<V2PlayerStats> {
  return request<V2PlayerStats>(
    'GET',
    communityPath(`/players/${enc(playerId)}/stats`),
    undefined,
    signal,
  )
}

/** Stats in the wire shape, by id or by name. */
export async function getPlayerStatsRaw(
  nameOrId: string,
  signal?: AbortSignal,
): Promise<V2PlayerStats> {
  const playerId = await resolvePlayerId(nameOrId, signal)
  const stats = await fetchPlayerStats(playerId, signal)
  // One stats read teaches the name → id mapping, so the next reader of the
  // same player does not pay for a name lookup.
  if (stats.name) playerIdByName.set(stats.name.toLowerCase(), playerId)
  return stats
}

/** The id behind a name, when an earlier read already resolved it. */
export function knownPlayerId(nameOrId: string): string | null {
  if (/^[0-9a-f-]{36}$/i.test(nameOrId)) return nameOrId
  return playerIdByName.get(nameOrId.toLowerCase()) ?? null
}

export function toPlayerStats(data: V2PlayerStats): PlayerStats {
  return {
    name: data.name,
    playerId: data.playerId,
    gamesPlayed: data.games,
    wins: data.wins,
    losses: data.losses,
    pointsFor: 0,
    pointsAgainst: 0,
    // v2 ranking breakdown keys entries by session id, and the old career card
    // joins on `share_code`; the id is the stable key on both sides.
    sessions: (data.sessions ?? []).map((session) => ({
      ...session,
      share_code: session.share_code ?? session.id,
    })),
    topPartners: data.topPartners ?? [],
    topOpponents: data.topOpponents ?? [],
    tournamentStats: {
      ...(data.tournamentStats ?? {
        gamesPlayed: 0,
        wins: 0,
        losses: 0,
        tournaments: [],
        topPartners: [],
        topOpponents: [],
      }),
      tournaments: (data.tournamentStats?.tournaments ?? []).map((event) => ({
        ...event,
        share_code: event.share_code ?? (event as { id?: string }).id ?? '',
      })),
    },
  }
}

export async function getPlayerStats(name: string, signal?: AbortSignal): Promise<PlayerStats> {
  return toPlayerStats(await getPlayerStatsRaw(name, signal))
}

export async function registerPlayer(
  name: string,
  canonicalName?: string,
  gender?: Gender,
): Promise<{ playerId: string }> {
  if (canonicalName !== undefined) {
    // v1's second argument meant "register this spelling as an alias of the
    // canonical player". v2 stores aliases on the player row.
    const playerId = await resolvePlayerId(canonicalName)
    const player = await request<V2Player>(
      'GET',
      communityPath(`/players/${enc(playerId)}`),
    )
    const aliases = [...new Set([...(player.aliases ?? []), name])]
    await request<V2Player>('PATCH', communityPath(`/players/${enc(playerId)}`), { aliases })
    // An alias is not part of the summary the snapshot joins, so the cached
    // rows stay valid.
    return { playerId }
  }
  const player = await request<V2Player>('POST', communityPath('/players'), {
    name,
    gender: gender ?? undefined,
  }, undefined, { 'Idempotency-Key': makeIdempotencyKey() })
  // A new player joins the cache instead of emptying it: the next screen
  // should not re-read the whole roster because one row appeared.
  const cached = cachedPlayers()
  if (cached !== null) {
    const summary = toPlayerSummary(player)
    playerCache = [...cached.filter((row) => row.playerId !== summary.playerId), summary]
    playerCacheSlug = activeCommunitySlug()
  }
  playerIdByName.set(String(player.name).toLowerCase(), player.id)
  return { playerId: player.id }
}

// ── Tournaments ───────────────────────────────────────────────────────────

export interface TournamentMeta {
  id: string
  name: string
  date: string
  format: 'classic' | 'team'
}

export async function listTournaments(signal?: AbortSignal): Promise<TournamentMeta[]> {
  const body = await request<{ items: Array<{ id: string; name: string; date: string; format?: string }> }>(
    'GET',
    communityPath('/tournaments'),
    undefined,
    signal,
  )
  if (!Array.isArray(body?.items)) {
    console.warn('[listTournaments] response is not an array:', body)
    throw new ApiError('Invalid tournament list received from server')
  }
  return body.items.map((row) => ({
    id: row.id,
    name: row.name,
    date: row.date,
    format: row.format === 'team' ? 'team' : 'classic',
  }))
}

export async function getTournament(id: string, signal?: AbortSignal): Promise<AnyTournamentSnapshot | null> {
  try {
    return await request<AnyTournamentSnapshot>(
      'GET',
      communityPath(`/tournaments/${enc(id)}`),
      undefined,
      signal,
    )
  } catch (error) {
    if (isNotFound(error)) return null
    throw error
  }
}

export async function publishTournament(id: string, data: AnyTournamentSnapshot): Promise<AnyTournamentSnapshot> {
  return request<AnyTournamentSnapshot>(
    'PUT',
    communityPath(`/tournaments/${enc(id)}`),
    data,
    undefined,
    { ...ifMatch(data.version), 'Idempotency-Key': makeIdempotencyKey() },
  )
}

export async function createTournament(
  data: AnyTournamentSnapshot,
): Promise<{ id: string; snapshot: AnyTournamentSnapshot }> {
  const { data: snapshot, headers } = await request<AnyTournamentSnapshot>(
    'POST',
    communityPath('/tournaments'),
    data,
    undefined,
    { 'Idempotency-Key': makeIdempotencyKey() },
    true,
  )
  const location = headers.get('Location') ?? ''
  const snapshotId = (snapshot as { id?: string }).id
  const id = location.split('/').pop() ?? snapshotId ?? ''
  return { id, snapshot }
}

// ── Rating ────────────────────────────────────────────────────────────────

export interface RatingHistoryRow {
  date: string
  title: string
  game_ref: string
  outcome: 'W' | 'L'
  score_a: number
  score_b: number
  teammates: string[]
  opponents: string[]
}

export interface RatingPlayer {
  name: string
  tier: string
  games: number
  wins: number
  losses: number
  history: RatingHistoryRow[]
}

/** The rating card's view of the same stats payload the career card reads. */
export function toRatingPlayer(stats: V2PlayerStats): RatingPlayer {
  return {
    name: stats.name,
    tier: stats.tier ?? '',
    games: stats.games,
    wins: stats.wins,
    losses: stats.losses,
    history: (stats.history ?? []).map((row) => ({
      date: row.date,
      title: row.title,
      game_ref: row.gameRef,
      outcome: row.outcome,
      score_a: row.scoreA,
      score_b: row.scoreB,
      teammates: row.teammates,
      opponents: row.opponents,
    })),
  }
}

export async function getRatingPlayer(playerId: string, signal?: AbortSignal): Promise<RatingPlayer> {
  return toRatingPlayer(await getPlayerStatsRaw(playerId, signal))
}

export interface AchievementRow {
  key: string
  kind: string
  title: string
  detail: string
  note?: string
  value?: number
  tierLevel?: number
  tierName?: string
  nextTarget?: number
  thresholds?: number[]
  earnedAt: string
  meta?: Record<string, string>
}

type V2Achievement = {
  key: string
  category: string
  threshold: number
  earnedAt: string
  kind?: string
  title?: string
  detail?: string
  note?: string
  value?: number
  tierLevel?: number | null
  tierName?: string | null
  nextTarget?: number | null
  thresholds?: number[]
  meta?: Record<string, string>
}

function humanizeKey(key: string): string {
  return key
    .split(/[._-]/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(' ')
}

/** The restored v1 UI names medals `medal:<family>`; v2 drops the prefix. */
function legacyAchievementKey(key: string): string | null {
  if (key.startsWith('tournament:')) return key
  const metric = key.slice(0, key.indexOf(':'))
  if (metric === 'rank_streak') return 'medal:rank_streak'
  // v1 had no tournament-count or tier ladder: tournaments show up as event
  // medals, and tier is the player's class, not a badge.
  if (['sessions', 'games', 'wins', 'streak', 'partners', 'opponents', 'rank'].includes(metric)) {
    return `medal:${metric}`
  }
  return null
}

export async function getPlayerAchievements(
  playerId: string,
  signal?: AbortSignal,
): Promise<AchievementRow[]> {
  const body = await request<{ items: V2Achievement[] } | null>(
    'GET',
    communityPath(`/players/${enc(playerId)}/achievements`),
    undefined,
    signal,
  )
  const rows = (body?.items ?? []).flatMap((item) => {
    const key = legacyAchievementKey(item.key)
    if (key === null) return []
    return [{
      key,
      kind: item.kind ?? item.category,
      title: item.title ?? humanizeKey(item.key),
      detail: item.detail ?? '',
      note: item.note ?? '',
      value: item.value ?? item.threshold,
      tierLevel: item.tierLevel ?? undefined,
      tierName: item.tierName ?? undefined,
      nextTarget: item.nextTarget ?? undefined,
      thresholds: item.thresholds,
      earnedAt: item.earnedAt,
      meta: item.meta ?? {},
    }]
  })
  // v2 earns one row per crossed threshold, while v1 kept one row per family.
  // Collapse them so the shelf shows the family once, at its best rung.
  const best = new Map<string, AchievementRow>()
  for (const row of rows) {
    const previous = best.get(row.key)
    if (previous === undefined) {
      best.set(row.key, row)
      continue
    }
    const value = row.value ?? 0
    const before = previous.value ?? 0
    const better = row.key === 'medal:rank' ? value < before : value > before
    if (better) best.set(row.key, row)
  }
  return [...best.values()]
}

export interface RankPointEntry {
  source_id: string
  date: string
  kind: string
  points: number
  games: number
}

export interface RankPointRow {
  rank: number
  player_id: string
  name: string
  tier?: string
  points: number
  counted_entries: number
  entries_available: number
  thin_evidence: boolean
  prev_rank: number | null
  rank_delta: number | null
  breakdown: RankPointEntry[]
}

export interface RankPointsBoard {
  window_weeks: number
  best_n: number
  min_sessions: number
  as_of: string
  rows: RankPointRow[]
}

type V2RankingRow = {
  rank: number
  playerId: string
  name: string
  tier: string | null
  points: number
  games: number
  wins: number
  losses: number
  prevRank?: number | null
  rankDelta?: number | null
  countedEntries?: number
  entriesAvailable?: number
  thinEvidence?: boolean
  breakdown?: Array<{ sourceId: string; date: string; kind: string; points: number; games: number }>
}

type V2RankingsBoard = {
  asOf: string
  items: V2RankingRow[]
  windowWeeks?: number
  bestN?: number
  minSessions?: number
}

function toRankPointRow(row: V2RankingRow): RankPointRow {
  return {
    rank: row.rank,
    player_id: row.playerId,
    name: row.name,
    tier: row.tier ?? undefined,
    points: row.points,
    counted_entries: row.countedEntries ?? row.games,
    entries_available: row.entriesAvailable ?? row.games,
    thin_evidence: row.thinEvidence ?? false,
    prev_rank: row.prevRank ?? null,
    rank_delta: row.rankDelta ?? null,
    breakdown: (row.breakdown ?? []).map((entry) => ({
      source_id: entry.sourceId,
      date: entry.date,
      kind: entry.kind,
      points: entry.points,
      games: entry.games,
    })),
  }
}

export async function getRankings(
  limit: number,
  minSessions?: number,
  signal?: AbortSignal,
): Promise<RankPointsBoard> {
  const query = new URLSearchParams({ limit: String(limit) })
  if (minSessions != null) query.set('min_sessions', String(minSessions))
  const body = await request<V2RankingsBoard>(
    'GET',
    communityPath(`/rankings?${query.toString()}`),
    undefined,
    signal,
  )
  return {
    window_weeks: body?.windowWeeks ?? 0,
    best_n: body?.bestN ?? 0,
    min_sessions: body?.minSessions ?? 0,
    as_of: body?.asOf ?? '',
    rows: (body?.items ?? []).map(toRankPointRow),
  }
}

export interface PlayerRankPoints {
  found: boolean
  row?: RankPointRow
  min_sessions?: number
}

export async function getPlayerRankPoints(
  playerId: string,
  signal?: AbortSignal,
): Promise<PlayerRankPoints> {
  try {
    const row = await request<V2RankingRow>(
      'GET',
      communityPath(`/rankings/${enc(playerId)}`),
      undefined,
      signal,
    )
    return { found: true, row: toRankPointRow(row) }
  } catch (error) {
    if (isNotFound(error)) return { found: false, min_sessions: 0 }
    throw error
  }
}
