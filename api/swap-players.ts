import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError, colFromTarget } from './_db.js'

interface SwapTarget {
  slot: number
  court: number
  playerId: string
  team: 'A' | 'B'
  index: 0 | 1
}

// Execute a single-column update by column name (avoids sql.unsafe)
async function updateCol(
  sql: ReturnType<typeof getDb>,
  id: string,
  col: string,
  value: string,
) {
  if (col === 'team_a_p1') await sql`UPDATE games SET team_a_p1 = ${value} WHERE id = ${id}`
  else if (col === 'team_a_p2') await sql`UPDATE games SET team_a_p2 = ${value} WHERE id = ${id}`
  else if (col === 'team_b_p1') await sql`UPDATE games SET team_b_p1 = ${value} WHERE id = ${id}`
  else if (col === 'team_b_p2') await sql`UPDATE games SET team_b_p2 = ${value} WHERE id = ${id}`
  else throw new Error(`Invalid column: ${col}`)
}

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'POST') return sendError(res, 'Method not allowed', 405)

  const { sessionId, t1, t2 } = req.body as {
    sessionId: string
    t1: SwapTarget
    t2: SwapTarget
  }
  if (!sessionId || !t1 || !t2) return sendError(res, 'Missing fields', 400)

  const sql = getDb()
  const id1 = `${sessionId}-${t1.slot}-${t1.court}`
  const id2 = `${sessionId}-${t2.slot}-${t2.court}`
  const col1 = colFromTarget(t1.team, t1.index)
  const col2 = colFromTarget(t2.team, t2.index)
  const sameGame = id1 === id2

  if (sameGame) {
    await updateCol(sql, id1, col1, t2.playerId)
    await updateCol(sql, id1, col2, t1.playerId)
  } else {
    await updateCol(sql, id1, col1, t2.playerId)
    await updateCol(sql, id2, col2, t1.playerId)
  }

  return send(res, null)
}
