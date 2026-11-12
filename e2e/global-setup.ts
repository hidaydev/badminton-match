import { execFileSync } from 'node:child_process'
import { createHash, randomBytes } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { request } from 'playwright/test'
import {
  GROUP_IDS,
  generateGroupMatches,
  initKnockoutMatches,
} from '../apps/web/src/legacy/utils/tournament'
import type { APIRequestContext } from 'playwright/test'
import { projects } from './browsers'
import { drawGroups } from './draw'
import type { E2eState } from './visual.routes'

/**
 * Bootstraps one community with the data the visual baseline needs. Login goes
 * through the OIDC stub (T-085), never Google: the stub's default identity is
 * the address the API was booted with, so the first login is the platform owner.
 */
const here = __dirname

/**
 * The fixture handoff is per run: `.state/run-<id>.json`, plus a `current`
 * marker naming the newest one. Two runs on one machine must not read each
 * other's community ids, and the workers are separate processes from the one
 * that ran the setup, so the name travels in the marker instead of a variable.
 * `E2E_RUN_ID` names the run explicitly when a caller wants that.
 */
const stateDir = join(here, '.state')

function runId(): string {
  const named = process.env.E2E_RUN_ID
  if (named) return named
  const marker = join(stateDir, 'current')
  if (existsSync(marker)) return readFileSync(marker, 'utf8').trim()
  return `unsaved-${process.pid}`
}

export function statePath(): string {
  return join(stateDir, `run-${runId()}.json`)
}

export function state(): E2eState {
  return JSON.parse(readFileSync(statePath(), 'utf8')) as E2eState
}

const baseURL = process.env.E2E_BASE_URL ?? 'http://127.0.0.1:5173'

type Game = { round: number; court: number; sideA: string[]; sideB: string[] }

/** Writes a schedule and returns the session version the server now holds. */
async function putGames(
  api: APIRequestContext,
  slug: string,
  sessionId: string,
  games: Game[],
  version: number,
): Promise<number> {
  const response = await api.put(`/api/c/${slug}/sessions/${sessionId}/schedule`, {
    headers: { 'If-Match': `"${version}"` },
    data: { games },
  })
  if (response.status() !== 200) {
    throw new Error(`schedule: ${response.status()} ${await response.text()}`)
  }
  return ((await response.json()) as { version: number }).version
}

async function playGame(
  api: APIRequestContext,
  slug: string,
  sessionId: string,
  key: string,
  score: { scoreA: number; scoreB: number },
  version: number,
): Promise<number> {
  const response = await api.patch(
    `/api/c/${slug}/sessions/${sessionId}/games/${key}`,
    { headers: { 'If-Match': `"${version}"` }, data: score },
  )
  if (response.status() !== 200) {
    throw new Error(`score: ${response.status()} ${await response.text()}`)
  }
  return ((await response.json()) as { version: number }).version
}

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
    // The write specs save scores and bump a session's updated_at, which moves
    // it in the list the visual baseline pins. They get their own community so
    // the pinned list never depends on which spec ran first.
    const writes = await api.post('/api/communities', {
      data: { slug: 'e2e-writes', name: 'E2E Writes', adminEmail: 'stub@example.com' },
    })
    if (writes.status() !== 201) {
      throw new Error(`writes community: ${writes.status()} ${await writes.text()}`)
    }
    // The creator is not a member yet: the first-admin invitation is honoured
    // at login, so a second pass through the stub is what grants admin.
    await startLogin(api)

    // Settings renders the membership's `created_at`, which is the day the
    // suite happens to run. Pin it, or the settings baseline goes stale every
    // midnight. The DSN is the one `task.d/e2e.sh` already migrated.
    const dsn = process.env.MAJADU_PG_DSN
    if (!dsn) throw new Error('MAJADU_PG_DSN is required to pin the fixture dates')
    execFileSync('psql', [
      dsn,
      '-v',
      'ON_ERROR_STOP=1',
      '-c',
      `update community.membership set created_at = timestamptz '2026-11-01 00:00:00+07'
         where community_id in (select id from platform.community where slug in ('e2e-club', 'e2e-writes'))`,
    ])

    // QA-18: a lower role cannot be reached through the stub, which signs in one
    // identity, so the member is a row plus a live session. Only the cookie is
    // stored; the same sha256 hex the API writes is in the database, so the
    // suite exercises the real session path rather than a test bypass.
    const memberToken = randomBytes(32).toString('hex')
    const memberHash = (value: string) =>
      createHash('sha256').update(value).digest('hex')
    execFileSync('psql', [
      dsn,
      '-v',
      'ON_ERROR_STOP=1',
      '-c',
      `with member as (
         insert into platform.user (google_sub, email_hash, display_name)
         values ('e2e-member', '${memberHash('member@example.invalid')}', 'E2E Member')
         on conflict (google_sub) do update set display_name = excluded.display_name
         returning id
       ), membership as (
         -- The settings screen prints this row's created_at, and the pin above
         -- only reaches the rows that already exist. Carry the date the visual
         -- baseline was recorded, or the settings shot goes stale at midnight.
         insert into community.membership (community_id, user_id, role, created_at)
         select c.id, m.id, 'member', timestamptz '2026-11-11 00:00:00+07'
           from member m, platform.community c
          where c.slug = 'e2e-club'
         on conflict (community_id, user_id)
           do update set role = 'member', created_at = excluded.created_at
       )
       insert into account.sessions (user_id, token_hash, absolute_expires_at)
       select id, decode('${memberHash(memberToken)}', 'hex'), now() + interval '1 day'
         from member`,
    ])

    const playerIds: string[] = []
    for (const name of ['Ani', 'Budi', 'Candra', 'Dewi']) {
      const player = await api.post('/api/c/e2e-club/players', { data: { name } })
      if (player.status() !== 201) {
        throw new Error(`players: ${player.status()} ${await player.text()}`)
      }
      playerIds.push(((await player.json()) as { id: string }).id)
    }
    const writePlayerIds: string[] = []
    for (const name of ['Wira', 'Xena', 'Yudi', 'Zara']) {
      const player = await api.post('/api/c/e2e-writes/players', { data: { name } })
      if (player.status() !== 201) {
        throw new Error(`writes players: ${player.status()} ${await player.text()}`)
      }
      writePlayerIds.push(((await player.json()) as { id: string }).id)
    }

    const session = await api.post('/api/c/e2e-club/sessions', {
      data: { title: 'E2E Wednesday', date: '2026-11-04', startTime: '19:00' },
    })
    if (session.status() !== 201) {
      throw new Error(`sessions: ${session.status()} ${await session.text()}`)
    }
    const sessionId = ((await session.json()) as { id: string }).id
    // The pinned session is what the visual baseline shows, so it carries the
    // states worth looking at: a played game and one still scheduled.
    let version = await putGames(api, 'e2e-club', sessionId, [
      { round: 0, court: 0, sideA: [playerIds[0], playerIds[1]], sideB: [playerIds[2], playerIds[3]] },
      { round: 0, court: 1, sideA: [playerIds[0], playerIds[2]], sideB: [playerIds[1], playerIds[3]] },
    ], 1)
    version = await playGame(api, 'e2e-club', sessionId, '0-0', { scoreA: 30, scoreB: 24 }, version)
    if (version !== 3) throw new Error(`pinned session version: ${version}`)

    // SEC-09 shares only an approved session, and approval is the lock, so the
    // spectator fixture is its own session: locking the pinned one would take
    // the continue-card off the home screen and freeze every baseline that
    // expects a draft. The same games keep the shared page worth looking at.
    const shareSession = await api.post('/api/c/e2e-club/sessions', {
      data: {
        title: 'E2E Approved Wednesday',
        date: '2026-11-04',
        startTime: '19:00',
      },
    })
    if (shareSession.status() !== 201) {
      throw new Error(`share session: ${shareSession.status()} ${await shareSession.text()}`)
    }
    const shareSessionId = ((await shareSession.json()) as { id: string }).id
    const shareTitle = 'E2E Approved Wednesday'
    let shareVersion = await putGames(api, 'e2e-club', shareSessionId, [
      { round: 0, court: 0, sideA: [playerIds[0], playerIds[1]], sideB: [playerIds[2], playerIds[3]] },
      { round: 0, court: 1, sideA: [playerIds[0], playerIds[2]], sideB: [playerIds[1], playerIds[3]] },
    ], 1)
    shareVersion = await playGame(api, 'e2e-club', shareSessionId, '0-0', { scoreA: 30, scoreB: 24 }, shareVersion)
    const lock = await api.post(`/api/c/e2e-club/sessions/${shareSessionId}/lock`, {
      headers: { 'If-Match': `"${shareVersion}"` },
    })
    if (lock.status() !== 200) {
      throw new Error(`lock: ${lock.status()} ${await lock.text()}`)
    }

    // The spectator spec opens this without a login; nothing else writes it.
    const share = await api.post(`/api/c/e2e-club/sessions/${shareSessionId}/share`)
    if (share.status() !== 201) {
      throw new Error(`share: ${share.status()} ${await share.text()}`)
    }
    const shareCode = ((await share.json()) as { code: string }).code

    // Writable sessions live beside the pinned one: the write specs change
    // them, and two projects run in parallel, so each project gets its own.
    //
    // There are two families, because `fullyParallel` runs one spec file's
    // tests beside another file's: `E2E Writable` belongs to the single-writer
    // spec and `E2E OCC` to the two-writer one, so neither can bump the other's
    // version mid-test. Both are named per project so the sessions list reads as
    // a fixture, not as duplicates someone forgot to delete.
    async function writableSessionFor(prefix: string, date: string,
        project: (typeof projects)[number]): Promise<string> {
      const created = await api.post('/api/c/e2e-writes/sessions', {
        data: { title: `${prefix} ${project.name}`, date, startTime: '19:00' },
      })
      if (created.status() !== 201) {
        throw new Error(`${prefix} session: ${created.status()} ${await created.text()}`)
      }
      const id = ((await created.json()) as { id: string }).id
      await putGames(api, 'e2e-writes', id, [
        { round: 0, court: 0, sideA: [writePlayerIds[0], writePlayerIds[1]], sideB: [writePlayerIds[2], writePlayerIds[3]] },
      ], 1)
      return id
    }

    const writableByProject: Record<string, string> = {}
    const occByProject: Record<string, string> = {}
    for (const project of projects) {
      writableByProject[project.name] = await writableSessionFor(
        'E2E Writable', '2026-11-05', project)
      occByProject[project.name] = await writableSessionFor(
        'E2E OCC', '2026-11-06', project)
    }

    // The draw uses the same round robin and bracket slots the app does (and
    // its own copy of the group shuffle), so the fixture is a tournament the
    // server accepts instead of a hand-written shape that drifts from the
    // rules.
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

    mkdirSync(stateDir, { recursive: true })
    writeFileSync(join(stateDir, 'current'), `${process.env.E2E_RUN_ID ?? process.pid}\n`)
    writeFileSync(
      statePath(),
      JSON.stringify(
        {
          communitySlug: 'e2e-club',
          communityName: 'E2E Club',
          tournamentId,
          tournamentName: 'E2E Classic',
          sessionId,
          sessionTitle: 'E2E Wednesday',
          playerId: playerIds[0],
          playerName: 'Ani',
          shareCode,
          shareTitle,
          writableByProject,
          occByProject,
          writableCommunitySlug: 'e2e-writes',
          memberCookie: memberToken,
        },
        null,
        2,
      ) + '\n',
    )
  } finally {
    await api.dispose()
  }
}
