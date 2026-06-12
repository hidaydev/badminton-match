import type { CloudSnapshot, SessionMeta, PlayerSummary, PlayerStats } from './types'
import type { TournamentSnapshot } from '../utils/tournament'

export const TOURNAMENT_ID = 'tournament-2026-05-23-majadu'

function apiUrl(): string {
  return (import.meta.env.VITE_API_URL as string) ?? ''
}

function authHeader(): HeadersInit {
  return { Authorization: `Bearer ${import.meta.env.VITE_API_TOKEN as string}` }
}

async function apiFetch<T>(url: string, init?: RequestInit): Promise<T> {
  const res = await fetch(url, { ...init, headers: { ...authHeader(), ...(init?.headers as Record<string, string> | undefined) } })
  const json = await res.json() as { ok: boolean; data?: T; error?: string }
  if (!json.ok) throw new Error(json.error ?? 'API error')
  return json.data as T
}

export async function getSession(id: string): Promise<CloudSnapshot | null> {
  return apiFetch<CloudSnapshot | null>(`${apiUrl()}/api/session?id=${encodeURIComponent(id)}`)
}

export async function publishSession(id: string, data: CloudSnapshot): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/sessions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id, data }),
  })
}

export async function listSessions(): Promise<SessionMeta[]> {
  return apiFetch<SessionMeta[]>(`${apiUrl()}/api/sessions`)
}

export async function listPlayers(): Promise<PlayerSummary[]> {
  return apiFetch<PlayerSummary[]>(`${apiUrl()}/api/players`)
}

export async function getPlayerStats(name: string): Promise<PlayerStats> {
  return apiFetch<PlayerStats>(`${apiUrl()}/api/player-stats?name=${encodeURIComponent(name)}`)
}

export async function getTournament(id: string): Promise<TournamentSnapshot | null> {
  return apiFetch<TournamentSnapshot | null>(`${apiUrl()}/api/tournament?id=${encodeURIComponent(id)}`)
}

export async function publishTournament(id: string, data: TournamentSnapshot): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/tournament`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id, data }),
  })
}

export async function setGamePlayed(sessionId: string, gameId: string, played: boolean): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/game-played`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sessionId, gameId, played }),
  })
}

export async function setGameScore(sessionId: string, gameId: string, a: number, b: number): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/game-score`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sessionId, gameId, a, b }),
  })
}

export async function swapPlayers(sessionId: string, t1: unknown, t2: unknown): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/swap-players`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sessionId, t1, t2 }),
  })
}

export async function swapSlots(sessionId: string, g1: unknown, g2: unknown): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/swap-slots`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sessionId, g1, g2 }),
  })
}

export async function setAbsent(sessionId: string, playerIds: string[]): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/absent`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sessionId, playerIds }),
  })
}

export async function replacePlayer(sessionId: string, playerId: string, newName: string): Promise<void> {
  await apiFetch<null>(`${apiUrl()}/api/replace-player`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sessionId, playerId, newName }),
  })
}
