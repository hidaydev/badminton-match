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
    'Accept-Profile': 'bm',
    'Content-Profile': 'bm',
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

async function callRpc<T>(
  name: string,
  body: Record<string, unknown>,
): Promise<T> {
  const res = await fetch(rpcUrl(name), {
    method: 'POST',
    headers: rpcHeaders(),
    body: JSON.stringify(body),
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
    throw new RpcError(detail, code)
  }

  if (res.status === 204) return undefined as T
  return await res.json() as T
}

export async function getSession(id: string): Promise<CloudSnapshot | null> {
  return await callRpc<CloudSnapshot | null>('get_session', { p_id: id })
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
