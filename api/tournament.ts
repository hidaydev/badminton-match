import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db'
import type { TournamentSnapshot } from '../src/queries/types'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)

  const sql = getDb()

  if (req.method === 'GET') {
    const id = req.query.id as string
    if (!id) return sendError(res, 'Missing id', 400)
    const rows = await sql`SELECT data FROM tournaments WHERE id = ${id}`
    if (!rows.length) return send(res, null)
    return send(res, rows[0].data as TournamentSnapshot)
  }

  if (req.method === 'PUT') {
    const { id, data } = req.body as { id: string; data: TournamentSnapshot }
    if (!id || !data) return sendError(res, 'Missing fields', 400)
    const now = new Date().toISOString()
    await sql`
      INSERT INTO tournaments (id, data, created_at, updated_at)
      VALUES (${id}, ${JSON.stringify(data)}, ${now}, ${now})
      ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data, updated_at = EXCLUDED.updated_at
    `
    return send(res, null)
  }

  return sendError(res, 'Method not allowed', 405)
}
