import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db.js'

interface SlotSwapTarget { slot: number; court: number }

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'POST') return sendError(res, 'Method not allowed', 405)

  const { sessionId, g1, g2 } = req.body as {
    sessionId: string
    g1: SlotSwapTarget
    g2: SlotSwapTarget
  }
  if (!sessionId || !g1 || !g2) return sendError(res, 'Missing fields', 400)

  const sql = getDb()
  const id1 = `${sessionId}-${g1.slot}-${g1.court}`
  const id2 = `${sessionId}-${g2.slot}-${g2.court}`

  const rows = await sql`SELECT * FROM games WHERE id IN (${id1}, ${id2})`
  if (rows.length !== 2) return sendError(res, 'Games not found', 404)

  const row1 = rows.find((r) => r.id === id1)!
  const row2 = rows.find((r) => r.id === id2)!

  await sql`
    UPDATE games SET
      team_a_p1 = CASE id WHEN ${id1} THEN ${row2.team_a_p1} ELSE ${row1.team_a_p1} END,
      team_a_p2 = CASE id WHEN ${id1} THEN ${row2.team_a_p2} ELSE ${row1.team_a_p2} END,
      team_b_p1 = CASE id WHEN ${id1} THEN ${row2.team_b_p1} ELSE ${row1.team_b_p1} END,
      team_b_p2 = CASE id WHEN ${id1} THEN ${row2.team_b_p2} ELSE ${row1.team_b_p2} END,
      played    = CASE id WHEN ${id1} THEN ${row2.played}    ELSE ${row1.played}    END,
      score_a   = CASE id WHEN ${id1} THEN ${row2.score_a}   ELSE ${row1.score_a}   END,
      score_b   = CASE id WHEN ${id1} THEN ${row2.score_b}   ELSE ${row1.score_b}   END
    WHERE id IN (${id1}, ${id2})
  `

  return send(res, null)
}
