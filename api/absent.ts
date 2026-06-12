import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db.js'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'PUT') return sendError(res, 'Method not allowed', 405)

  const { sessionId, playerIds } = req.body as {
    sessionId: string
    playerIds: string[]
  }
  if (!sessionId || !Array.isArray(playerIds)) return sendError(res, 'Missing fields', 400)

  const sql = getDb()
  await sql`DELETE FROM absent_players WHERE session_id = ${sessionId}`
  for (const playerId of playerIds) {
    await sql`
      INSERT INTO absent_players (session_id, player_id) VALUES (${sessionId}, ${playerId})
      ON CONFLICT DO NOTHING
    `
  }
  return send(res, null)
}
