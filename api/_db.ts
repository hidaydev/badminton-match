import { neon } from '@neondatabase/serverless'
import type { VercelRequest, VercelResponse } from '@vercel/node'

export function getDb() {
  if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL not set')
  return neon(process.env.DATABASE_URL)
}

export function checkAuth(req: VercelRequest): boolean {
  const header = req.headers['authorization'] ?? ''
  const token = header.replace('Bearer ', '').trim()
  return !!process.env.API_TOKEN && token === process.env.API_TOKEN
}

export function send(res: VercelResponse, data: unknown, status = 200) {
  return res.status(status).json({ ok: true, data })
}

export function sendError(res: VercelResponse, error: string, status = 500) {
  return res.status(status).json({ ok: false, error })
}

export function withErrorHandler(
  fn: (req: VercelRequest, res: VercelResponse) => Promise<void | VercelResponse>
) {
  return async (req: VercelRequest, res: VercelResponse) => {
    try {
      await fn(req, res)
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Internal server error'
      sendError(res, message, 500)
    }
  }
}

export function gameId(sessionId: string, slot: number, court: number) {
  return `${sessionId}-${slot}-${court}`
}

export function colFromTarget(team: 'A' | 'B', index: 0 | 1): string {
  if (team === 'A') return index === 0 ? 'team_a_p1' : 'team_a_p2'
  return index === 0 ? 'team_b_p1' : 'team_b_p2'
}
