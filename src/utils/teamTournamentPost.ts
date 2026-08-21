// src/utils/teamTournamentPost.ts — Canvas post generator untuk team tournament.
// Frame unik: dark gradient background dengan accent color border.

import { canvasToBlob } from './share'
import type { TeamTournamentSnapshot, TeamStandingRow } from './teamTournament'

const WIDTH = 1080
const HEIGHT = 1080
const PADDING = 60

// Colors
const BG_START = '#0f172a' // slate-900
const BG_END = '#1e293b'   // slate-800
const ACCENT = '#6366f1'   // indigo-500
const TEXT_FG = '#f8fafc'  // slate-50
const TEXT_DIM = '#94a3b8'  // slate-400
const BORDER = '#334155'    // slate-700

/**
 * Generate Instagram post canvas untuk team tournament standings.
 * Returns blob JPEG siap share/download.
 */
export async function generateTeamStandingsPost(
  snap: TeamTournamentSnapshot,
  standings: TeamStandingRow[],
): Promise<Blob | null> {
  const canvas = document.createElement('canvas')
  canvas.width = WIDTH
  canvas.height = HEIGHT
  const ctx = canvas.getContext('2d')
  if (!ctx) return null

  // ── Background gradient ──────────────────────────────────────────────
  const grad = ctx.createLinearGradient(0, 0, 0, HEIGHT)
  grad.addColorStop(0, BG_START)
  grad.addColorStop(1, BG_END)
  ctx.fillStyle = grad
  ctx.fillRect(0, 0, WIDTH, HEIGHT)

  // ── Accent border ────────────────────────────────────────────────────
  ctx.strokeStyle = ACCENT
  ctx.lineWidth = 4
  const borderR = 20
  ctx.beginPath()
  ctx.roundRect(PADDING / 2, PADDING / 2, WIDTH - PADDING, HEIGHT - PADDING, borderR)
  ctx.stroke()

  // ── Inner border ─────────────────────────────────────────────────────
  ctx.strokeStyle = BORDER
  ctx.lineWidth = 1
  ctx.beginPath()
  ctx.roundRect(PADDING, PADDING, WIDTH - PADDING * 2, HEIGHT - PADDING * 2, 12)
  ctx.stroke()

  let y = PADDING + 50

  // ── Title ────────────────────────────────────────────────────────────
  ctx.fillStyle = TEXT_FG
  ctx.font = 'bold 42px system-ui, -apple-system, sans-serif'
  ctx.textAlign = 'center'
  ctx.fillText(snap.name, WIDTH / 2, y)
  y += 40

  // ── Subtitle ─────────────────────────────────────────────────────────
  ctx.fillStyle = TEXT_DIM
  ctx.font = '20px system-ui, -apple-system, sans-serif'
  ctx.fillText(`${snap.date} · ${snap.teams.length} teams`, WIDTH / 2, y)
  y += 50

  // ── Divider line ─────────────────────────────────────────────────────
  ctx.strokeStyle = BORDER
  ctx.lineWidth = 1
  ctx.beginPath()
  ctx.moveTo(PADDING + 40, y)
  ctx.lineTo(WIDTH - PADDING - 40, y)
  ctx.stroke()
  y += 40

  // ── Standings rows ───────────────────────────────────────────────────
  const rowH = 90
  const isTeamMode = snap.format === 'team'

  for (let i = 0; i < standings.length; i++) {
    const r = standings[i]
    const isChampion = i === 0
    const rowY = y + i * rowH

    // Row background
    if (isChampion) {
      ctx.fillStyle = 'rgba(99, 102, 241, 0.1)' // accent/10
      ctx.beginPath()
      ctx.roundRect(PADDING + 20, rowY - 10, WIDTH - PADDING * 2 - 40, rowH - 5, 8)
      ctx.fill()
    }

    // Rank number
    ctx.fillStyle = isChampion ? ACCENT : TEXT_DIM
    ctx.font = `bold 28px "SF Mono", "Cascadia Code", "Fira Code", monospace`
    ctx.textAlign = 'left'
    const rankLabel = isChampion ? '👑' : `${i + 1}`
    ctx.fillText(rankLabel, PADDING + 40, rowY + 35)

    // Team name
    ctx.fillStyle = TEXT_FG
    ctx.font = 'bold 26px system-ui, -apple-system, sans-serif'
    const nameX = isChampion ? PADDING + 90 : PADDING + 80
    ctx.fillText(r.teamName, nameX, rowY + 35)

    // Stats (right-aligned)
    ctx.fillStyle = TEXT_DIM
    ctx.font = '20px "SF Mono", "Cascadia Code", "Fira Code", monospace'
    ctx.textAlign = 'right'
    const stats = `${r.points}pt · ${r.teamWins}-${r.teamLosses}`
    ctx.fillText(stats, WIDTH - PADDING - 40, rowY + 35)

    // Team members (if team mode)
    if (isTeamMode) {
      const team = snap.teams.find((t) => t.id === r.teamId)
      if (team && team.players.length > 0) {
        ctx.fillStyle = TEXT_DIM
        ctx.font = '16px "SF Mono", "Cascadia Code", "Fira Code", monospace'
        ctx.textAlign = 'left'
        const members = team.players.map((p) => `${p.cls} ${p.name}`).join('  ·  ')
        ctx.fillText(members, nameX, rowY + 58)
      }
    }
  }

  y += standings.length * rowH + 30

  // ── Footer ───────────────────────────────────────────────────────────
  ctx.fillStyle = TEXT_DIM
  ctx.font = '16px system-ui, -apple-system, sans-serif'
  ctx.textAlign = 'center'
  ctx.fillText('Majadu · Team Tournament', WIDTH / 2, HEIGHT - PADDING - 30)

  // ── Convert to blob ──────────────────────────────────────────────────
  return canvasToBlob(canvas, 0.95)
}
