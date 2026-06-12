import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db.js'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'PATCH') return sendError(res, 'Method not allowed', 405)

  const { sessionId, gameId, a, b } = req.body as {
    sessionId: string
    gameId: string
    a: number
    b: number
  }
  if (!sessionId || !gameId || a == null || b == null) return sendError(res, 'Missing fields', 400)

  const sql = getDb()
  const id = `${sessionId}-${gameId}`
  await sql`UPDATE games SET score_a = ${a}, score_b = ${b}, played = true WHERE id = ${id}`
  return send(res, null)
}
