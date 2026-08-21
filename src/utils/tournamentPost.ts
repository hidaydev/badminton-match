// src/utils/tournamentPost.ts — Canvas post generator untuk team tournament standings.
// Frame: photo background + summary-bg texture + tournament badge + card overlay.

import { canvasToBlob } from './share'
import { loadImage } from './canvasPost'
import type { TeamTournamentSnapshot, TeamStandingRow } from './teamTournament'
import { tournamentTemplate } from '../config/tournamentTemplates'

const W = tournamentTemplate.width
const H = tournamentTemplate.height
const PADDING = 50

// Colors
const ACCENT = '#6366f1'
const TEXT_FG = '#f8fafc'
const TEXT_DIM = '#94a3b8'

/**
 * Generate Instagram post canvas untuk team tournament standings.
 * Supports optional user photo sebagai background.
 * Returns blob JPEG siap share/download.
 */
export async function generateTeamStandingsPost(
  snap: TeamTournamentSnapshot,
  standings: TeamStandingRow[],
  userPhoto?: HTMLImageElement,
): Promise<Blob | null> {
  const canvas = document.createElement('canvas')
  canvas.width = W
  canvas.height = H
  const ctx = canvas.getContext('2d')
  if (!ctx) return null

  // ── Load overlay images ──────────────────────────────────────────────
  let bgImg: HTMLImageElement | undefined
  let badgeImg: HTMLImageElement | undefined
  let logoImg: HTMLImageElement | undefined
  let sponsorImg: HTMLImageElement | undefined

  try {
    const [bg, badge, logo, sponsor] = await Promise.allSettled([
      tournamentTemplate.background ? loadImage(tournamentTemplate.background) : Promise.reject('no bg'),
      tournamentTemplate.badge ? loadImage(tournamentTemplate.badge) : Promise.reject('no badge'),
      tournamentTemplate.logo ? loadImage(tournamentTemplate.logo) : Promise.reject('no logo'),
      tournamentTemplate.sponsor ? loadImage(tournamentTemplate.sponsor) : Promise.reject('no sponsor'),
    ])
    if (bg.status === 'fulfilled') bgImg = bg.value
    if (badge.status === 'fulfilled') badgeImg = badge.value
    if (logo.status === 'fulfilled') logoImg = logo.value
    if (sponsor.status === 'fulfilled') sponsorImg = sponsor.value
  } catch {
    // proceed without overlays
  }

  // ── Layer 1: Background ──────────────────────────────────────────────
  if (userPhoto) {
    // Photo as background (cover-fill, blurred)
    drawCoverFill(ctx, userPhoto, W, H, 0, 0)
    // Dark overlay for readability
    ctx.fillStyle = 'rgba(15, 23, 42, 0.75)'
    ctx.fillRect(0, 0, W, H)
  } else if (bgImg) {
    // Summary-bg texture
    drawCoverFill(ctx, bgImg, W, H, 0, 0)
    ctx.fillStyle = 'rgba(15, 23, 42, 0.6)'
    ctx.fillRect(0, 0, W, H)
  } else {
    // Fallback: dark gradient
    const grad = ctx.createLinearGradient(0, 0, 0, H)
    grad.addColorStop(0, '#0f172a')
    grad.addColorStop(0.5, '#1e293b')
    grad.addColorStop(1, '#0f172a')
    ctx.fillStyle = grad
    ctx.fillRect(0, 0, W, H)
  }

  // ── Layer 2: Decorative border ───────────────────────────────────────
  ctx.strokeStyle = ACCENT
  ctx.lineWidth = 3
  ctx.beginPath()
  ctx.roundRect(PADDING / 2, PADDING / 2, W - PADDING, H - PADDING, 16)
  ctx.stroke()

  // Inner border
  ctx.strokeStyle = 'rgba(99, 102, 241, 0.2)'
  ctx.lineWidth = 1
  ctx.beginPath()
  ctx.roundRect(PADDING, PADDING, W - PADDING * 2, H - PADDING * 2, 12)
  ctx.stroke()

  // ── Layer 3: Champion badge (top center) ─────────────────────────────
  if (badgeImg) {
    const badgeSize = 120
    const badgeX = (W - badgeSize) / 2
    const badgeY = PADDING + 30
    ctx.globalAlpha = 0.15
    ctx.drawImage(badgeImg, badgeX, badgeY, badgeSize, badgeSize)
    ctx.globalAlpha = 1
  }

  // ── Layer 4: Title ───────────────────────────────────────────────────
  let y = PADDING + 60

  ctx.fillStyle = TEXT_FG
  ctx.font = 'bold 44px "IBM Plex Sans", Arial, sans-serif'
  ctx.textAlign = 'center'
  ctx.fillText(snap.name, W / 2, y)
  y += 45

  // Date + teams subtitle
  ctx.fillStyle = TEXT_DIM
  ctx.font = '20px "IBM Plex Sans", Arial, sans-serif'
  ctx.fillText(`${snap.date} · ${snap.teams.length} teams`, W / 2, y)
  y += 40

  // Accent line
  const lineW = 200
  ctx.strokeStyle = ACCENT
  ctx.lineWidth = 2
  ctx.beginPath()
  ctx.moveTo((W - lineW) / 2, y)
  ctx.lineTo((W + lineW) / 2, y)
  ctx.stroke()
  y += 30

  // ── Layer 5: Champion announcement ───────────────────────────────────
  const championId = standings[0]?.teamId
  const championTeam = snap.teams.find((t) => t.id === championId)
  if (championTeam) {
    // Champion card
    const champY = y
    const champH = 80
    ctx.fillStyle = 'rgba(99, 102, 241, 0.12)'
    ctx.beginPath()
    ctx.roundRect(PADDING + 30, champY, W - PADDING * 2 - 60, champH, 10)
    ctx.fill()

    ctx.strokeStyle = ACCENT
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.roundRect(PADDING + 30, champY, W - PADDING * 2 - 60, champH, 10)
    ctx.stroke()

    ctx.fillStyle = ACCENT
    ctx.font = '14px "IBM Plex Mono", monospace'
    ctx.textAlign = 'center'
    ctx.fillText('🏆 CHAMPION', W / 2, champY + 25)

    ctx.fillStyle = TEXT_FG
    ctx.font = 'bold 28px "IBM Plex Sans", Arial, sans-serif'
    ctx.fillText(championTeam.name, W / 2, champY + 58)

    y = champY + champH + 20
  }

  // ── Layer 6: Standings table ─────────────────────────────────────────
  const rowH = 70
  const tableStartY = y

  for (let i = 0; i < standings.length; i++) {
    const r = standings[i]
    const rowY = tableStartY + i * rowH
    const team = snap.teams.find((t) => t.id === r.teamId)
    const isChampion = i === 0

    // Row background
    if (isChampion) {
      ctx.fillStyle = 'rgba(99, 102, 241, 0.08)'
      ctx.beginPath()
      ctx.roundRect(PADDING + 20, rowY, W - PADDING * 2 - 40, rowH - 8, 8)
      ctx.fill()
    }

    // Rank
    const medals = ['👑', '🥈', '🥉']
    ctx.fillStyle = isChampion ? ACCENT : TEXT_DIM
    ctx.font = i < 3 ? '24px Arial' : 'bold 20px "IBM Plex Mono", monospace'
    ctx.textAlign = 'left'
    const rankLabel = i < 3 ? medals[i] : `${i + 1}`
    ctx.fillText(rankLabel, PADDING + 40, rowY + 32)

    // Team name
    ctx.fillStyle = isChampion ? ACCENT : TEXT_FG
    ctx.font = `bold 22px "IBM Plex Sans", Arial, sans-serif`
    const nameX = PADDING + 80
    ctx.fillText(r.teamName, nameX, rowY + 32)

    // Stats (right)
    ctx.fillStyle = TEXT_DIM
    ctx.font = '18px "IBM Plex Mono", monospace'
    ctx.textAlign = 'right'
    ctx.fillText(`${r.points}pt · ${r.teamWins}-${r.teamLosses}`, W - PADDING - 40, rowY + 32)

    // Members (small text under name)
    if (team && team.players.length > 0) {
      ctx.fillStyle = TEXT_DIM
      ctx.font = '13px "IBM Plex Mono", monospace'
      ctx.textAlign = 'left'
      const members = team.players.map((p) => `${p.cls} ${p.name}`).join('  ·  ')
      const maxMemberW = W - PADDING * 2 - 200
      ctx.fillText(truncateToWidth(ctx, members, maxMemberW), nameX, rowY + 52)
    }
  }

  y = tableStartY + standings.length * rowH + 30

  // ── Layer 7: Footer ──────────────────────────────────────────────────
  // Accent line
  ctx.strokeStyle = ACCENT
  ctx.lineWidth = 1
  ctx.beginPath()
  ctx.moveTo(PADDING + 40, y)
  ctx.lineTo(W - PADDING - 40, y)
  ctx.stroke()
  y += 25

  // Logo
  if (logoImg) {
    const logoH = 24
    const logoW = logoH * (logoImg.naturalWidth / logoImg.naturalHeight)
    ctx.drawImage(logoImg, (W - logoW) / 2, y, logoW, logoH)
    y += logoH + 15
  }

  // Sponsor
  if (sponsorImg) {
    const sH = 40
    const sW = sH * (sponsorImg.naturalWidth / sponsorImg.naturalHeight)
    ctx.drawImage(sponsorImg, (W - sW) / 2, y, sW, sH)
  }

  // ── Convert to blob ──────────────────────────────────────────────────
  return canvasToBlob(canvas, 0.95)
}

// ── Helpers ────────────────────────────────────────────────────────────────

function drawCoverFill(
  ctx: CanvasRenderingContext2D,
  img: HTMLImageElement,
  canvasW: number,
  canvasH: number,
  offsetX: number,
  offsetY: number,
) {
  if (!img.naturalWidth || !img.naturalHeight) return
  const scale = Math.max(canvasW / img.naturalWidth, canvasH / img.naturalHeight)
  const w = img.naturalWidth * scale
  const h = img.naturalHeight * scale
  const x = (canvasW - w) / 2 + offsetX
  const y = (canvasH - h) / 2 + offsetY
  ctx.drawImage(img, x, y, w, h)
}

function truncateToWidth(ctx: CanvasRenderingContext2D, text: string, maxWidth: number): string {
  let truncated = text
  while (ctx.measureText(truncated + '…').width > maxWidth && truncated.length > 1) {
    truncated = truncated.slice(0, -1)
  }
  if (truncated !== text) truncated += '…'
  return truncated
}
