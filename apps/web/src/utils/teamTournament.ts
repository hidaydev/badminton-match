// src/utils/teamTournament.ts
// Format tournament TIM: 6 tim × 6 pemain (6 kelas), 3 partai ganda per
// team-match, rally 30 (grup) / 42 (final), top-2 → final.
// Mirror kontrak backend (apps/api/internal/domain/team_tournament.go).

import type { TournamentSnapshot } from './tournament'
import { drawMatchPost, drawTeamMatchPost, loadImage, ANNIVERSARY_LABEL, type TeamMatchPartaiRow } from './canvasPost'
import { canvasToBlob } from './share'

export type TeamClass = 'A+' | 'A' | 'B+' | 'B' | 'C+' | 'C'
export type TeamPhase = 'group' | 'final'

export interface TeamPlayer {
  name: string
  cls: TeamClass
}

export interface TeamInfo {
  id: string
  name: string
  players: TeamPlayer[]
}

export interface TeamPartai {
  scoreA: number | null
  scoreB: number | null
}

export interface TeamMatch {
  id: string
  phase: TeamPhase
  teamA: string
  teamB: string
  partai: TeamPartai[]
  courts: [string, string, string] // satu entry per partai (boleh sama; default UI 12/13/14)
}

export interface TeamTournamentSnapshot {
  version?: number
  format: 'team'
  name: string
  date: string
  teams: TeamInfo[]
  matches: TeamMatch[]
}

/** Union snapshot — discriminated oleh `format`. */
export type AnyTournamentSnapshot = TournamentSnapshot | TeamTournamentSnapshot

/** 6 kelas valid. */
export const TEAM_CLASSES: TeamClass[] = ['A+', 'A', 'B+', 'B', 'C+', 'C']

/** Kelas pair per partai (urutan tetap): 0=C+ C · 1=A+ A · 2=B+ B. */
export const PARTAI_CLASSES: [TeamClass, TeamClass][] = [
  ['C+', 'C'],
  ['A+', 'A'],
  ['B+', 'B'],
]

/** Partai ke-i team A → id pemain kelas C+ (A+ / B+). */
export function partaiClassA(i: number): TeamClass {
  return PARTAI_CLASSES[i][0]
}

/** Partai ke-i team A → id pemain kelas C (A / B). */
export function partaiClassB(i: number): TeamClass {
  return PARTAI_CLASSES[i][1]
}

/** Skor target: grup 30, final 42. */
export function teamTarget(phase: TeamPhase): number {
  return phase === 'final' ? 42 : 30
}

/** Fallback array court (3 slot per team-match) selaras UI. 1 input = 3 slot sama. */
export const DEFAULT_TEAM_COURTS: [string, string, string] = ['Court 12', 'Court 13', 'Court 14']

/** true bila match lokal berbeda dari snapshot server (skor atau court). */
export function teamMatchDirty(local: TeamMatch, server: TeamMatch | undefined): boolean {
  if (!server) return true
  const lc = local.courts ?? DEFAULT_TEAM_COURTS
  const sc = server.courts ?? DEFAULT_TEAM_COURTS
  if (lc[0] !== sc[0] || lc[1] !== sc[1] || lc[2] !== sc[2]) return true
  if (local.partai.length !== server.partai.length) return true
  for (let i = 0; i < local.partai.length; i++) {
    if (local.partai[i].scoreA !== server.partai[i].scoreA || local.partai[i].scoreB !== server.partai[i].scoreB) {
      return true
    }
  }
  return false
}

// ── outcome & standings ────────────────────────────────────────────────────

export interface TeamOutcome {
  aWins: number
  bWins: number
  complete: boolean
}

/** Hitung partai yang dimenangkan tiap sisi. complete = semua 3 partai ada skor. */
export function teamMatchOutcome(match: TeamMatch): TeamOutcome {
  let aWins = 0
  let bWins = 0
  let complete = true
  for (const pt of match.partai) {
    // == null: null ATAU undefined (partai kosong) dianggap belum dimainkan
    if (pt.scoreA == null || pt.scoreB == null) {
      complete = false
      continue
    }
    if (pt.scoreA > pt.scoreB) aWins++
    else if (pt.scoreB > pt.scoreA) bWins++
  }
  return { aWins, bWins, complete }
}

export interface TeamStandingRow {
  teamId: string
  teamName: string
  played: number
  teamWins: number
  teamLosses: number
  points: number
  pointsFor: number
  pointsAgainst: number
}

/** Poin: menang 3-0 = 3 · 2-1 = 2 · kalah 1-2 = 1 · 0-3 = 0. */
export function teamMatchPoints(wins: number, losses: number): number {
  if (wins === 3) return 3
  if (wins === 2) return 2
  if (losses === 2) return 1
  return 0
}

/**
 * Klasemen grup:
 * 1. poin tertinggi
 * 2. selisih menang-kalah (teamWins - teamLosses) tertinggi
 * 3. selisih poin agregat (pointsFor - pointsAgainst) tertinggi
 *
 * Otoritas klien (by design): backend hanya menyimpan skor mentah + guard
 * struktural; poin/tiebreak & seeding final top-2 dihitung di sini. Jangan
 * diasumsikan divalidasi server. Aturan kelas/target dipin oleh golden fixture
 * (scripts/tests/fixtures/team-tournament.golden.json, dicek juga oleh test Go).
 */
export function computeTeamStandings(teams: TeamInfo[], matches: TeamMatch[]): TeamStandingRow[] {
  const rows: Record<string, TeamStandingRow> = {}
  for (const t of teams) {
    rows[t.id] = {
      teamId: t.id, teamName: t.name,
      played: 0, teamWins: 0, teamLosses: 0,
      points: 0, pointsFor: 0, pointsAgainst: 0,
    }
  }
  for (const m of matches) {
    const out = teamMatchOutcome(m)
    if (!out.complete) continue
    const a = rows[m.teamA]
    const b = rows[m.teamB]
    if (!a || !b) continue
    a.played++
    b.played++
    a.teamWins += out.aWins
    a.teamLosses += out.bWins
    b.teamWins += out.bWins
    b.teamLosses += out.aWins
    a.points += teamMatchPoints(out.aWins, out.bWins)
    b.points += teamMatchPoints(out.bWins, out.aWins)
    for (const pt of m.partai) {
      if (pt.scoreA === null || pt.scoreB === null) continue
      a.pointsFor += pt.scoreA
      a.pointsAgainst += pt.scoreB
      b.pointsFor += pt.scoreB
      b.pointsAgainst += pt.scoreA
    }
  }
  return Object.values(rows).sort((x, y) => {
    if (y.points !== x.points) return y.points - x.points
    const xDiff = x.teamWins - x.teamLosses
    const yDiff = y.teamWins - y.teamLosses
    if (yDiff !== xDiff) return yDiff - xDiff
    return (y.pointsFor - y.pointsAgainst) - (x.pointsFor - x.pointsAgainst)
  })
}

// ── undian/jadwal grup ───────────────────────────────────────────────────────

export type TeamDrawItem = [string, string, string] // [teamA, teamB, courtName]

/**
 * Jadwal 9 team-match fixed: 3 sesi × 3 lapangan (Court 12, 13, 14).
 * Tiap tim bertanding tepat 3× tanpa ulangan lawan.
 * Ids = [t1..t6] (Tim 1 s/d Tim 6).
 */
export function generateTeamDraw(teamIds: string[]): TeamDrawItem[] {
  if (teamIds.length !== 6) throw new Error('generateTeamDraw membutuhkan tepat 6 tim')
  const schedule: [number, number, string][] = [
    // Sesi 1
    [0, 1, 'Court 12'], // Tim 1 vs Tim 2
    [2, 3, 'Court 13'], // Tim 3 vs Tim 4
    [4, 5, 'Court 14'], // Tim 5 vs Tim 6
    // Sesi 2
    [3, 5, 'Court 12'], // Tim 4 vs Tim 6
    [0, 2, 'Court 13'], // Tim 1 vs Tim 3
    [1, 4, 'Court 14'], // Tim 2 vs Tim 5
    // Sesi 3
    [2, 4, 'Court 12'], // Tim 3 vs Tim 5
    [1, 5, 'Court 13'], // Tim 2 vs Tim 6
    [0, 3, 'Court 14'], // Tim 1 vs Tim 4
  ]
  return schedule.map(([a, b, court]) => [teamIds[a], teamIds[b], court])
}

export function teamName(teams: { id: string; name: string }[], id: string | undefined): string {
  return teams.find((t) => t.id === id)?.name ?? (id ?? '—')
}

/**
 * Susun entri tim sesuai undian hari-H. `slotToNamed[slot] = index named team`
 * (0..5 di TEAM_NAMES). Entri penuh dipindah (id slot + nama + roster), jadi
 * roster selalu ikut nama ke mana pun tim ditempatkan.
 */
export function buildTeamsByDraw(teams: TeamInfo[], slotToNamed: number[]): TeamInfo[] {
  const rosterByName = new Map(teams.map((t) => [t.name, t.players]))
  const out: TeamInfo[] = []
  for (let slot = 0; slot < slotToNamed.length; slot++) {
    const name = TEAM_NAMES[slotToNamed[slot]]
    if (name === undefined) continue
    out.push({ id: `t${slot + 1}`, name, players: rosterByName.get(name) ?? [] })
  }
  return out
}

/** 6 nama tim kanonik (fixed) — kunci mapping logo. Wajib tepat sekali per turnamen. */
export const TEAM_NAMES = [
  'RED RAPTORS',
  'WHITE FURY',
  'BLUE WAVES',
  'PURPLE PHANTOMS',
  'GREEN GROVE',
  'PINK SPECTRE',
] as const

export type TeamName = (typeof TEAM_NAMES)[number]

const TEAM_LOGO_MAP: Record<TeamName, string> = {
  'RED RAPTORS': '/team-logos/Red_Raptors_-removebg-preview.png',
  'WHITE FURY': '/team-logos/White_Fury-removebg-preview.png',
  'BLUE WAVES': '/team-logos/Blue_Waves-removebg-preview.png',
  'PURPLE PHANTOMS': '/team-logos/Purple_Phantoms_-removebg-preview.png',
  'GREEN GROVE': '/team-logos/Green_Grove-removebg-preview.png',
  'PINK SPECTRE': '/team-logos/Pink_Spectre-removebg-preview.png',
}

export function teamLogoPath(name: string): string | undefined {
  return TEAM_LOGO_MAP[name.trim().toUpperCase() as TeamName]
}

const TEAM_COLOR_MAP: Record<TeamName, string> = {
  'RED RAPTORS':     '180,20,20',
  'WHITE FURY':      '200,200,210',
  'BLUE WAVES':      '29,78,216',
  'PURPLE PHANTOMS': '70,20,140',
  'GREEN GROVE':     '10,80,35',
  'PINK SPECTRE':    '219,39,119',
}

export function teamColor(name: string): string {
  return TEAM_COLOR_MAP[name.trim().toUpperCase() as TeamName] ?? '80,80,80'
}

// ── export pipeline ──────────────────────────────────────────────────────────

/** Nama pasangan partai dari kelas dua pemain, mis. "Budi/Sari". */
export function getPairName(teams: TeamInfo[], teamId: string, clsA: string, clsB: string): string {
  const team = teams.find((t) => t.id === teamId)
  const p1 = team?.players.find((p) => p.cls === clsA)?.name ?? '—'
  const p2 = team?.players.find((p) => p.cls === clsB)?.name ?? '—'
  return `${p1}/${p2}`
}

export interface BuildTeamMatchFilesOptions {
  teams: TeamInfo[]
  match: TeamMatch
  partaiPhotos: Record<string, HTMLImageElement>
  /** Key foto per index partai di `partaiPhotos`. */
  photoKey: (partaiIdx: number) => string
  overlays: Record<string, HTMLImageElement | undefined>
  /** Subtitle post per partai; dilanjutkan ` · <kelas>`. */
  matchSubtitle: string
  summarySubtitle: string
  /** Prefix nama file, mis. `tim-a-vs-tim-b` atau `final`. */
  filePrefix: string
}

/**
 * Rantai export team-match: logo tim + placeholder, post per partai (hanya
 * yang punya foto & skor), lalu summary card. Caller menentukan prefix nama
 * file dan menambahkan post posisi (champion/runner-up) bila perlu.
 */
export async function buildTeamMatchFiles({
  teams, match, partaiPhotos, photoKey, overlays, matchSubtitle, summarySubtitle, filePrefix,
}: BuildTeamMatchFilesOptions): Promise<{ files: File[]; teamAName: string; teamBName: string }> {
  const out = teamMatchOutcome(match)
  const teamAName = teamName(teams, match.teamA)
  const teamBName = teamName(teams, match.teamB)
  const files: File[] = []

  const [teamALogoImg, teamBLogoImg, teamPhotoPlaceholder] = await Promise.all([
    teamLogoPath(teamAName) ? loadImage(teamLogoPath(teamAName)!).catch(() => undefined) : Promise.resolve(undefined),
    teamLogoPath(teamBName) ? loadImage(teamLogoPath(teamBName)!).catch(() => undefined) : Promise.resolve(undefined),
    loadImage('/team-photo-placeholder.png').catch(() => undefined),
  ])

  for (let pi = 0; pi < PARTAI_CLASSES.length; pi++) {
    const photo = partaiPhotos[photoKey(pi)]
    const p = match.partai[pi]
    if (!photo || p.scoreA === null || p.scoreB === null) continue
    const [clsA, clsB] = PARTAI_CLASSES[pi]
    const c = document.createElement('canvas')
    drawMatchPost({
      canvas: c,
      photo,
      pairAName: getPairName(teams, match.teamA, clsA, clsB),
      pairBName: getPairName(teams, match.teamB, clsA, clsB),
      scoreA: p.scoreA,
      scoreB: p.scoreB,
      subtitle: `${matchSubtitle} · ${clsA}${clsB}`,
      logo: overlays.logo,
      badge: overlays.badge,
      chevrons: overlays.chevrons,
      sponsor: overlays.sponsor,
      cardLogo: overlays.cardLogo,
      teamALogo: teamALogoImg,
      teamBLogo: teamBLogoImg,
      headerLabel: ANNIVERSARY_LABEL,
    })
    const blob = await canvasToBlob(c)
    if (blob) files.push(new File([blob], `${filePrefix}-${clsA}${clsB}.jpg`, { type: 'image/jpeg' }))
  }

  const partaiRows: TeamMatchPartaiRow[] = PARTAI_CLASSES.map(([clsA, clsB], pi) => ({
    tier: `${clsA}${clsB}`,
    nameA: getPairName(teams, match.teamA, clsA, clsB),
    nameB: getPairName(teams, match.teamB, clsA, clsB),
    scoreA: match.partai[pi].scoreA,
    scoreB: match.partai[pi].scoreB,
  }))
  const summaryCanvas = document.createElement('canvas')
  drawTeamMatchPost({
    canvas: summaryCanvas,
    teamAName,
    teamBName,
    teamAWins: out.aWins,
    teamBWins: out.bWins,
    partaiRows,
    subtitle: summarySubtitle,
    summaryBg: overlays.summaryBg,
    logo: overlays.logo,
    sponsor: overlays.sponsor,
    cardLogo: overlays.cardLogo,
    teamALogo: teamALogoImg,
    teamBLogo: teamBLogoImg,
    teamAPhoto: teamPhotoPlaceholder,
    teamBPhoto: teamPhotoPlaceholder,
    teamAColor: teamColor(teamAName),
    teamBColor: teamColor(teamBName),
  })
  const summaryBlob = await canvasToBlob(summaryCanvas)
  if (summaryBlob) files.push(new File([summaryBlob], `${filePrefix}-summary.jpg`, { type: 'image/jpeg' }))

  return { files, teamAName, teamBName }
}
