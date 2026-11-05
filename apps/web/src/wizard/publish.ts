import { ApiError, request } from '../auth/api'
import { createPlayer, listPlayers } from '../players/api'
import type { Player as ServerPlayer } from '../players/api'
import { getSession } from '../sessions/api'
import type { WizardDraft } from './context'
import { tierToLabel } from './tiers'
import type { Player } from './types'

export class PublishError extends Error {}

type SessionSummary = {
  id: string
  version: number
  status: string
}

function isPlaceholder(name: string): boolean {
  return /^(free|tbd|default|xxx|unknown|kosong|belum ada)( \d+)?$|^\?+$/i.test(name.trim())
}

async function resolvePlayers(slug: string, draft: Player[]): Promise<Map<string, string>> {
  const existing = await listPlayers(slug, { limit: 1000 })
  const byName = new Map<string, ServerPlayer>()
  for (const player of existing) byName.set(player.name.trim().toLowerCase(), player)

  const ids = new Map<string, string>()
  for (const player of draft) {
    if (isPlaceholder(player.name)) {
      throw new PublishError(`Remove the placeholder “${player.name}” before publishing.`)
    }
    const key = player.name.trim().toLowerCase()
    if (ids.has(key)) {
      throw new PublishError(`“${player.name}” appears twice. Rename one of them.`)
    }
    let server = byName.get(key)
    if (!server) {
      server = await createPlayer(slug, {
        name: player.name.trim(),
        gender: player.gender,
        tier: tierToLabel(player.tier),
      })
      byName.set(key, server)
    }
    ids.set(player.id, server.id)
  }
  return ids
}

async function createSession(slug: string, draft: WizardDraft): Promise<string> {
  const body = await request<{ id: string }>(`/c/${encodeURIComponent(slug)}/sessions`, {
    method: 'POST',
    body: JSON.stringify({
      title: draft.session.title.trim() || 'Session',
      date: draft.session.date,
      startTime: draft.session.sessionStart,
      slotMinutes: draft.session.slotMinutes,
    }),
  })
  return body.id
}

async function updateSession(slug: string, id: string, draft: WizardDraft): Promise<number> {
  const current = await getSession(slug, id)
  if (current.status !== 'draft') return current.version
  const updated = await request<SessionSummary>(
    `/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(id)}`,
    {
      method: 'PATCH',
      headers: { 'If-Match': `"${current.version}"` },
      body: JSON.stringify({
        title: draft.session.title.trim() || 'Session',
        date: draft.session.date,
        startTime: draft.session.sessionStart,
        slotMinutes: draft.session.slotMinutes,
      }),
    },
  )
  return updated.version
}

export type PublishResult = { sessionId: string; created: boolean }

/**
 * Write the wizard draft to the server: players first (the schedule references
 * them), then the schedule, then the lock that approves it. A retry after a
 * successful publish updates the same session instead of creating a second one.
 */
export async function publishDraft(slug: string, draft: WizardDraft): Promise<PublishResult> {
  if (draft.schedule.length === 0) throw new PublishError('Generate a schedule first.')

  const playerIds = await resolvePlayers(slug, draft.players)
  const created = draft.serverSessionId === null
  const sessionId = draft.serverSessionId ?? (await createSession(slug, draft))
  let version = await updateSession(slug, sessionId, draft)

  const games = draft.schedule.map((slot) => ({
    round: slot.slot,
    court: slot.court,
    sideA: slot.teamA.map((id) => playerIds.get(id) ?? id),
    sideB: slot.teamB.map((id) => playerIds.get(id) ?? id),
  }))

  try {
    const body = await request<{ version: number }>(
      `/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(sessionId)}/schedule`,
      {
        method: 'PUT',
        headers: { 'If-Match': `"${version}"` },
        body: JSON.stringify({ games }),
      },
    )
    version = body.version
  } catch (error) {
    if (error instanceof ApiError && error.status === 404 && created) {
      throw new PublishError('The session disappeared before the schedule was saved.')
    }
    throw error
  }

  await request<void>(`/c/${encodeURIComponent(slug)}/sessions/${encodeURIComponent(sessionId)}/lock`, {
    method: 'POST',
    headers: { 'If-Match': `"${version}"` },
  })

  return { sessionId, created }
}
