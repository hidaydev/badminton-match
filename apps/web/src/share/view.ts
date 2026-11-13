import type { GeneratorResult } from '../legacy/generator'
import type { GameScore, Player, PlayerId, ScheduleSlot } from '../legacy/types'
import { toGameKey, toPlayerId } from '../legacy/types'
import type { SharedSession } from './api'

/** Fallbacks for a payload from a build that has no session times yet. */
const DEFAULT_SESSION_START = '00:00'
const DEFAULT_SLOT_MINUTES = 60

/** Everything `SummaryModal` needs to draw the guest body. */
export interface GuestView {
  result: GeneratorResult
  playerMap: Map<string, Player>
  slotsPerCourt: number[]
  playedGames: string[]
  gameScores: Record<string, GameScore>
  sessionStart: string
  slotMinutes: number
  courtNames: string[]
  absentPlayers: string[]
}

/** A side is always two chips; a short side keeps its empty slot. */
function teamOf(side: string[]): [PlayerId, PlayerId] {
  return [toPlayerId(side[0] ?? ''), toPlayerId(side[1] ?? '')]
}

/**
 * The share payload carries names, not people: a guest has no roster, so the
 * name is the id. Two players with the same name are one chip on this screen,
 * which matches what the payload can prove.
 */
export function buildGuestView(session: SharedSession): GuestView {
  const playerMap = new Map<string, Player>()
  const schedule: ScheduleSlot[] = []
  const playedGames: string[] = []
  const gameScores: Record<string, GameScore> = {}

  for (const game of session.games) {
    schedule.push({
      slot: game.round,
      court: game.court,
      teamA: teamOf(game.sideA),
      teamB: teamOf(game.sideB),
    })

    for (const name of [...game.sideA, ...game.sideB]) {
      if (name === '' || playerMap.has(name)) continue
      playerMap.set(name, { id: toPlayerId(name), name, gender: 'M', tier: 4 })
    }

    const key = toGameKey(game.round, game.court)
    if (game.status === 'played') playedGames.push(key)
    if (game.scoreA !== null && game.scoreB !== null) {
      const score: GameScore = { a: game.scoreA, b: game.scoreB }
      if (game.sets !== undefined) score.sets = game.sets.map((set) => ({ a: set.a, b: set.b }))
      gameScores[key] = score
    }
  }

  // ScheduleGrid reads `Math.max(...slotsPerCourt)`, so this array is never
  // empty and every court it names has at least one slot.
  const courtCount = session.games.reduce((max, game) => Math.max(max, game.court + 1), 0)
  const slotsPerCourt = Array.from({ length: courtCount }, () => 1)
  for (const game of session.games) {
    slotsPerCourt[game.court] = Math.max(slotsPerCourt[game.court], game.round + 1)
  }

  const result: GeneratorResult = {
    schedule,
    playCount: {},
    sitCount: {},
    partnerWith: {},
    facedBy: {},
    unplacedFixMatches: [],
  }

  return {
    result,
    playerMap,
    slotsPerCourt,
    playedGames,
    gameScores,
    sessionStart: session.session.startTime ?? DEFAULT_SESSION_START,
    slotMinutes: session.session.slotMinutes ?? DEFAULT_SLOT_MINUTES,
    // Neither is in the public payload: a guest sees the court letter and no
    // absent marker, because the link is readable by anyone.
    courtNames: [],
    absentPlayers: [],
  }
}
