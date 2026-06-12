import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'PATCH') return sendError(res, 'Method not allowed', 405)

  const { sessionId, playerId, newName } = req.body as {
    sessionId: string
    playerId: string
    newName: string
  }
  if (!sessionId || !playerId || !newName) return sendError(res, 'Missing fields', 400)

  const sql = getDb()
  await sql`
    UPDATE session_players SET name = ${newName}
    WHERE id = ${playerId} AND session_id = ${sessionId}
  `
  return send(res, null)
}
