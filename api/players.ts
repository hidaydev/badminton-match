import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db.js'
import type { PlayerSummary } from '../src/queries/types'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'GET') return sendError(res, 'Method not allowed', 405)

  const sql = getDb()
  const rows = await sql`
    SELECT DISTINCT ON (name) name, gender, tier
    FROM session_players
    ORDER BY name, session_id DESC
  `
  const data: PlayerSummary[] = rows.map((r) => ({
    name: r.name as string,
    gender: r.gender as 'M' | 'F',
    tier: r.tier as 1 | 2 | 3 | 4,
  }))
  return send(res, data)
}
