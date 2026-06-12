import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db'
import type { CloudSnapshot } from '../src/queries/types'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'GET') return sendError(res, 'Method not allowed', 405)

  const id = req.query.id as string
  if (!id) return sendError(res, 'Missing id', 400)

  const sql = getDb()

  const [sessionRows, playerRows, gameRows, fixRows, absentRows] = await Promise.all([
    sql`SELECT * FROM sessions WHERE id = ${id}`,
    sql`SELECT * FROM session_players WHERE session_id = ${id}`,
    sql`SELECT * FROM games WHERE session_id = ${id} ORDER BY slot, court`,
    sql`SELECT * FROM fix_matches WHERE session_id = ${id}`,
    sql`SELECT player_id FROM absent_players WHERE session_id = ${id}`,
  ])

  if (!sessionRows.length) return send(res, null)

  const s = sessionRows[0]
  const snapshot: CloudSnapshot = {
    session: {
      title: (s.title ?? '') as string,
      date: String(s.date).slice(0, 10),
      courts: (s.slots_per_court as number[]).length,
      sessionStart: s.session_start as string,
      slotMinutes: s.slot_minutes as number,
      courtTimes: s.court_times as { start: string; end: string }[],
      playerCount: playerRows.length,
      slotsPerCourt: s.slots_per_court as number[],
      totalGames: gameRows.length,
      courtNames: s.court_names as string[],
      locked: true,
    },
    players: playerRows.map((p) => ({
      id: p.id as string,
      name: p.name as string,
      gender: p.gender as 'M' | 'F',
      tier: p.tier as 1 | 2 | 3 | 4,
    })),
    fixMatches: fixRows.map((f) => ({ id: f.id as string, slots: f.slots as [string, string, string, string] })),
    schedule: gameRows.map((g) => ({
      slot: g.slot as number,
      court: g.court as number,
      teamA: [g.team_a_p1, g.team_a_p2] as [string, string],
      teamB: [g.team_b_p1, g.team_b_p2] as [string, string],
    })),
    playedGames: gameRows.filter((g) => g.played).map((g) => `${g.slot}-${g.court}`),
    gameScores: Object.fromEntries(
      gameRows
        .filter((g) => g.score_a != null)
        .map((g) => [`${g.slot}-${g.court}`, { a: g.score_a as number, b: g.score_b as number }])
    ),
    absentPlayers: absentRows.map((r) => r.player_id as string),
  }

  return send(res, snapshot)
}
