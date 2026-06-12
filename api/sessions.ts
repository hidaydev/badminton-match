import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db.js'
import type { CloudSnapshot, SessionMeta } from '../src/queries/types'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)

  const sql = getDb()

  if (req.method === 'GET') {
    const rows = await sql`
      SELECT s.id, s.title, s.date, s.updated_at,
        COUNT(DISTINCT sp.id)::int AS player_count,
        COUNT(DISTINCT g.id)::int AS total_games
      FROM sessions s
      LEFT JOIN session_players sp ON sp.session_id = s.id
      LEFT JOIN games g ON g.session_id = s.id
      GROUP BY s.id
      ORDER BY s.date DESC
    `
    const data: SessionMeta[] = rows.map((r) => ({
      id: r.id as string,
      title: (r.title ?? '') as string,
      date: r.date ? String(r.date).slice(0, 10) : '',
      playerCount: r.player_count as number,
      totalGames: r.total_games as number,
    }))
    return send(res, data)
  }

  if (req.method === 'POST') {
    const snap = req.body as { id: string; data: CloudSnapshot }
    const { id, data } = snap
    if (!id || !data) return sendError(res, 'Missing fields', 400)
    const s = data.session
    const now = new Date().toISOString()

    await sql`
      INSERT INTO sessions (id, title, date, session_start, slot_minutes, slots_per_court, court_names, court_times, tier_count, created_at, updated_at)
      VALUES (${id}, ${s.title}, ${s.date}, ${s.sessionStart}, ${s.slotMinutes},
        ${s.slotsPerCourt}, ${s.courtNames}, ${JSON.stringify(s.courtTimes)},
        ${4}, ${now}, ${now})
      ON CONFLICT (id) DO UPDATE SET
        title = EXCLUDED.title, date = EXCLUDED.date,
        session_start = EXCLUDED.session_start, slot_minutes = EXCLUDED.slot_minutes,
        slots_per_court = EXCLUDED.slots_per_court, court_names = EXCLUDED.court_names,
        court_times = EXCLUDED.court_times, tier_count = EXCLUDED.tier_count,
        updated_at = EXCLUDED.updated_at
    `

    for (const p of data.players) {
      await sql`
        INSERT INTO session_players (id, session_id, name, gender, tier)
        VALUES (${p.id}, ${id}, ${p.name}, ${p.gender}, ${p.tier})
        ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, gender = EXCLUDED.gender, tier = EXCLUDED.tier
      `
    }

    const playedSet = new Set(data.playedGames)
    for (const g of data.schedule) {
      const gid = `${id}-${g.slot}-${g.court}`
      const key = `${g.slot}-${g.court}`
      const score = data.gameScores?.[key]
      const played = playedSet.has(key)
      await sql`
        INSERT INTO games (id, session_id, slot, court, team_a_p1, team_a_p2, team_b_p1, team_b_p2, played, score_a, score_b)
        VALUES (${gid}, ${id}, ${g.slot}, ${g.court}, ${g.teamA[0]}, ${g.teamA[1]}, ${g.teamB[0]}, ${g.teamB[1]},
          ${played}, ${score?.a ?? null}, ${score?.b ?? null})
        ON CONFLICT (id) DO UPDATE SET
          team_a_p1 = EXCLUDED.team_a_p1, team_a_p2 = EXCLUDED.team_a_p2,
          team_b_p1 = EXCLUDED.team_b_p1, team_b_p2 = EXCLUDED.team_b_p2,
          played = EXCLUDED.played, score_a = EXCLUDED.score_a, score_b = EXCLUDED.score_b
      `
    }

    await sql`DELETE FROM fix_matches WHERE session_id = ${id}`
    for (const fm of data.fixMatches ?? []) {
      await sql`
        INSERT INTO fix_matches (id, session_id, slots) VALUES (${fm.id}, ${id}, ${fm.slots})
        ON CONFLICT (id) DO NOTHING
      `
    }

    await sql`DELETE FROM absent_players WHERE session_id = ${id}`
    for (const playerId of data.absentPlayers ?? []) {
      await sql`
        INSERT INTO absent_players (session_id, player_id) VALUES (${id}, ${playerId})
        ON CONFLICT DO NOTHING
      `
    }

    await sql`UPDATE sessions SET updated_at = ${now} WHERE id = ${id}`
    return send(res, null)
  }

  return sendError(res, 'Method not allowed', 405)
}
