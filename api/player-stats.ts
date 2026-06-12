import type { VercelRequest, VercelResponse } from '@vercel/node'
import { getDb, checkAuth, send, sendError } from './_db'
import type { PlayerStats } from '../src/queries/types'

export default async function handler(req: VercelRequest, res: VercelResponse) {
  if (!checkAuth(req)) return sendError(res, 'Unauthorized', 401)
  if (req.method !== 'GET') return sendError(res, 'Method not allowed', 405)

  const name = req.query.name as string
  if (!name) return sendError(res, 'Missing name', 400)

  const sql = getDb()

  const gameRows = await sql`
    SELECT g.*, s.date, s.title, s.id AS sid, sp.id AS target_id
    FROM games g
    JOIN session_players sp ON sp.id IN (g.team_a_p1, g.team_a_p2, g.team_b_p1, g.team_b_p2)
    JOIN sessions s ON s.id = g.session_id
    WHERE sp.name ILIKE ${name} AND g.played = true
  `

  const allPlayerIds = new Set<string>()
  for (const g of gameRows) {
    for (const col of ['team_a_p1', 'team_a_p2', 'team_b_p1', 'team_b_p2']) {
      const val = g[col] as string | null
      if (val) allPlayerIds.add(val)
    }
  }

  const playerRows = allPlayerIds.size
    ? await sql`SELECT id, name FROM session_players WHERE id = ANY(${Array.from(allPlayerIds)})`
    : []
  const nameMap = new Map<string, string>(
    (playerRows as { id: string; name: string }[]).map((p) => [p.id, p.name])
  )

  const partnerCount = new Map<string, { count: number; wins: number; losses: number }>()
  const opponentCount = new Map<string, { count: number; wins: number; losses: number }>()
  const sessionSet = new Map<string, { id: string; date: string; title: string }>()
  let gamesPlayed = 0, wins = 0, losses = 0, pointsFor = 0, pointsAgainst = 0

  for (const g of gameRows) {
    const targetId = g.target_id as string
    const onTeamA = [g.team_a_p1 as string, g.team_a_p2 as string].includes(targetId)
    const myTeam = onTeamA
      ? [g.team_a_p1 as string, g.team_a_p2 as string]
      : [g.team_b_p1 as string, g.team_b_p2 as string]
    const oppTeam = onTeamA
      ? [g.team_b_p1 as string, g.team_b_p2 as string]
      : [g.team_a_p1 as string, g.team_a_p2 as string]
    const myScore = onTeamA ? ((g.score_a ?? 0) as number) : ((g.score_b ?? 0) as number)
    const oppScore = onTeamA ? ((g.score_b ?? 0) as number) : ((g.score_a ?? 0) as number)
    const won = myScore > oppScore

    gamesPlayed++
    if (won) wins++; else losses++
    pointsFor += myScore
    pointsAgainst += oppScore

    sessionSet.set(g.sid as string, {
      id: g.sid as string,
      date: String(g.date).slice(0, 10),
      title: g.title as string,
    })

    for (const pid of myTeam) {
      if (!pid || pid === targetId) continue
      const pname = nameMap.get(pid) ?? pid
      const entry = partnerCount.get(pname) ?? { count: 0, wins: 0, losses: 0 }
      entry.count++; if (won) entry.wins++; else entry.losses++
      partnerCount.set(pname, entry)
    }
    for (const pid of oppTeam) {
      if (!pid) continue
      const pname = nameMap.get(pid) ?? pid
      const entry = opponentCount.get(pname) ?? { count: 0, wins: 0, losses: 0 }
      entry.count++; if (won) entry.wins++; else entry.losses++
      opponentCount.set(pname, entry)
    }
  }

  const toSorted = (m: Map<string, { count: number; wins: number; losses: number }>) =>
    Array.from(m.entries())
      .map(([n, v]) => ({ name: n, ...v }))
      .sort((a, b) => b.count - a.count)
      .slice(0, 10)

  const data: PlayerStats = {
    name,
    gamesPlayed,
    wins,
    losses,
    pointsFor,
    pointsAgainst,
    sessions: Array.from(sessionSet.values()).sort((a, b) => b.date.localeCompare(a.date)),
    topPartners: toSorted(partnerCount),
    topOpponents: toSorted(opponentCount),
  }

  return send(res, data)
}
