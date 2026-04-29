import type { SessionConfig, Player, FixMatch, ScheduleSlot, GameScore } from '../store'

export interface CloudSnapshot {
  session: SessionConfig
  players: Player[]
  fixMatches: FixMatch[]
  schedule: ScheduleSlot[]
  playedGames: string[]
  gameScores: Record<string, GameScore>
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
