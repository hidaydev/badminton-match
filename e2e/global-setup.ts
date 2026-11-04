import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { request } from 'playwright/test'
import {
  GROUP_IDS,
  drawGroups,
  generateGroupMatches,
  initKnockoutMatches,
} from '../apps/web/src/tournament/classic/draw'
import type { APIRequestContext } from 'playwright/test'
import type { E2eState } from './visual.routes'

/**
 * Bootstraps one community with the data the visual baseline needs. Login goes
 * through the OIDC stub (T-085), never Google: the stub's default identity is
 * the address the API was booted with, so the first login is the platform owner.
 */
const here = __dirname
export const statePath = join(here, '.state.json')

export function state(): E2eState {
  return JSON.parse(readFileSync(statePath, 'utf8')) as E2eState
}

const baseURL = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:5173'

async function startLogin(api: APIRequestContext) {
  const start = await api.post('/api/auth/start', { data: { returnTo: '/' } })
  if (!start.ok()) throw new Error(`auth/start: ${start.status()}`)
  const { authorizeUrl } = (await start.json()) as { authorizeUrl: string }
  const callback = await api.get(authorizeUrl)
  if (!callback.ok()) throw new Error(`authorize: ${callback.status()}`)
  const me = await api.get('/api/auth/me')
  if (!me.ok()) throw new Error(`auth/me: ${me.status()}`)
  return (await me.json()) as { id: string }
}

export default async function globalSetup() {
  // The CSRF guard needs the origin a browser would send; this context has none.
  const api = await request.newContext({ baseURL, extraHTTPHeaders: { Origin: baseURL } })
  try {
    await startLogin(api)

    const created = await api.post('/api/communities', {
      data: { slug: 'e2e-club', name: 'E2E Club', adminEmail: 'stub@example.com' },
    })
    if (created.status() !== 201) {
      throw new Error(`communities: ${created.status()} ${await created.text()}`)
    }
    // The creator is not a member yet: the first-admin invitation is honoured
    // at login, so a second pass through the stub is what grants admin.
    await startLogin(api)

    for (const name of ['Ani', 'Budi', 'Candra', 'Dewi']) {
      const player = await api.post('/api/c/e2e-club/players', { data: { name } })
      if (player.status() !== 201) {
        throw new Error(`players: ${player.status()} ${await player.text()}`)
      }
    }

    const session = await api.post('/api/c/e2e-club/sessions', {
      data: { title: 'E2E Wednesday', date: '2026-11-04', startTime: '19:00' },
    })
    if (session.status() !== 201) {
      throw new Error(`sessions: ${session.status()} ${await session.text()}`)
    }
    const sessionId = ((await session.json()) as { id: string }).id

    // The wizard's own draw, so the fixture is a tournament the app considers
    // valid instead of a hand-written shape that drifts from the rules.
    const pairIds = Array.from({ length: 16 }, (_, index) => `p${index + 1}`)
    const pairs = pairIds.map((id, index) => ({
      id,
      name: `Player ${index * 2 + 1} & Player ${index * 2 + 2}`,
    }))
    const groups = drawGroups(pairIds, 7)
    const matches = [
      ...GROUP_IDS.flatMap((groupId) => generateGroupMatches(groupId, groups[groupId])),
      ...initKnockoutMatches(),
    ]
    for (const match of matches) {
      if (match.id === 'group-A-0') {
        match.scoreA = 30
        match.scoreB = 24
      }
      if (match.id === 'group-A-1') {
        match.scoreA = 21
        match.scoreB = 30
      }
      if (match.id === 'group-B-0') {
        match.scoreA = 27
        match.scoreB = 29
      }
    }

    const tournament = await api.post('/api/c/e2e-club/tournaments', {
      headers: { 'Idempotency-Key': 'e2e-classic' },
      data: { name: 'E2E Classic', date: '2026-11-04', pairs, groups, matches },
    })
    if (tournament.status() !== 201) {
      throw new Error(`tournaments: ${tournament.status()} ${await tournament.text()}`)
    }
    const tournamentId = ((await tournament.json()) as { id: string }).id

    mkdirSync(here, { recursive: true })
    writeFileSync(
      statePath,
      JSON.stringify({ communitySlug: 'e2e-club', tournamentId, sessionId }, null, 2) + '\n',
    )
  } finally {
    await api.dispose()
  }
}
