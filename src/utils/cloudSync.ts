import type { SessionConfig, Player, FixMatch, ScheduleSlot, GameScore } from '../store'
import type { TournamentSnapshot } from './tournament'

export interface CloudSnapshot {
  session: SessionConfig
  players: Player[]
  fixMatches: FixMatch[]
  schedule: ScheduleSlot[]
  playedGames: string[]
  gameScores: Record<string, GameScore>
  absentPlayers?: string[]
}

export interface SessionMeta {
  id: string
  title: string
  date: string
  playerCount: number
  totalGames: number
}

export interface PlayerSummary {
  name: string
  gender: 'M' | 'F'
  tier: 1 | 2 | 3 | 4
}

export interface PlayerStats {
  name: string
  gamesPlayed: number
  wins: number
  losses: number
  pointsFor: number
  pointsAgainst: number
  sessions: { id: string; date: string; title: string; absent?: boolean }[]
  topPartners: { name: string; count: number; wins: number; losses: number }[]
  topOpponents: { name: string; count: number; wins: number; losses: number }[]
}

function scriptUrl(): string {
  const url = import.meta.env.VITE_APPS_SCRIPT_URL as string
  if (!url) throw new Error('VITE_APPS_SCRIPT_URL is not set')
  return url
}

export async function getSession(id: string): Promise<CloudSnapshot | null> {
  const res = await fetch(`${scriptUrl()}?id=${encodeURIComponent(id)}`)
  const json = await res.json() as { ok: boolean; data?: CloudSnapshot; error?: string }
  if (!json.ok) return null
  return json.data ?? null
}

export async function publishSession(id: string, data: CloudSnapshot): Promise<void> {
  const res = await fetch(scriptUrl(), {
    method: 'POST',
    // No Content-Type header: browser sends text/plain, avoiding CORS preflight.
    // Apps Script reads body via e.postData.contents.
    body: JSON.stringify({ id, data }),
  })
  const json = await res.json() as { ok: boolean; error?: string }
  if (!json.ok) throw new Error(json.error ?? 'publish failed')
}

export async function listSessions(): Promise<SessionMeta[]> {
  const res = await fetch(`${scriptUrl()}?action=list`)
  const json = await res.json() as { ok: boolean; data?: SessionMeta[]; error?: string }
  if (!json.ok) throw new Error(json.error ?? 'list failed')
  return json.data ?? []
}

export async function listPlayers(): Promise<PlayerSummary[]> {
  const res = await fetch(`${scriptUrl()}?action=players`)
  const json = await res.json() as { ok: boolean; data?: PlayerSummary[]; error?: string }
  if (!json.ok) throw new Error(json.error ?? 'list players failed')
  return json.data ?? []
}

export async function getPlayerStats(name: string): Promise<PlayerStats> {
  const res = await fetch(`${scriptUrl()}?action=playerStats&name=${encodeURIComponent(name)}`)
  const json = await res.json() as { ok: boolean; data?: PlayerStats; error?: string }
  if (!json.ok) throw new Error(json.error ?? 'player stats failed')
  if (!json.data) throw new Error('no data')
  return json.data
}

export const TOURNAMENT_ID = 'tournament-2026-05-23-majadu'
export type { TournamentSnapshot }

export async function getTournament(id: string): Promise<TournamentSnapshot | null> {
  const res = await fetch(`${scriptUrl()}?action=getTournament&id=${encodeURIComponent(id)}`)
  const json = await res.json() as { ok: boolean; data?: TournamentSnapshot; error?: string }
  if (!json.ok) return null
  return json.data ?? null
}

export async function publishTournament(id: string, data: TournamentSnapshot): Promise<void> {
  const res = await fetch(scriptUrl(), {
    method: 'POST',
    // No Content-Type header: browser sends text/plain, avoiding CORS preflight.
    // Apps Script reads body via e.postData.contents.
    body: JSON.stringify({ type: 'tournament', id, data }),
  })
  const json = await res.json() as { ok: boolean; error?: string }
  if (!json.ok) throw new Error(json.error ?? 'publish tournament failed')
}
