import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'PATCH') return sendError(res, 'Method not allowed', 405)

  const { sessionId, gameId, played } = req.body as {
    sessionId: string
    gameId: string
    played: boolean
  }
  if (!sessionId || !gameId || played == null) return sendError(res, 'Missing fields', 400)

  const sql = getDb()
  const id = `${sessionId}-${gameId}`
  await sql`UPDATE games SET played = ${played} WHERE id = ${id}`
  return send(res, null)
}
