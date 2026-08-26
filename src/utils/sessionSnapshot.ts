import type { CloudSnapshot, MatchConstraint, Player, ScheduleSlot, SessionConfig, GameKey } from '../types'
import { applySwap, applyTeamSwap, type SwapTarget, type TeamSwapTarget } from './swap.ts'
import { applySlotSwap, swapKeys, swapKeyInList, type SlotSwapTarget } from './slotSwap.ts'
import { validateScore } from './scoreValidation.ts'

interface PublishableSessionInput {
  version?: number
  existingAbsentPlayers?: string[]
  session: SessionConfig
  players: Player[]
  fixMatches: MatchConstraint[]
  schedule: ScheduleSlot[]
  playedGames: string[]
  gameScores: CloudSnapshot['gameScores']
}

export function buildPublishableSessionSnapshot({
  version,
  existingAbsentPlayers,
  session,
  players,
  fixMatches,
  schedule,
  playedGames,
  gameScores,
}: PublishableSessionInput): CloudSnapshot {
  return {
    version,
    session,
    players,
    fixMatches,
    schedule,
    playedGames,
    gameScores,
    absentPlayers: existingAbsentPlayers ?? [],
  }
}

export function togglePlayedInSnapshot(snapshot: CloudSnapshot, key: string): CloudSnapshot {
  const isPlayed = snapshot.playedGames.includes(key)
  const playedGames = isPlayed
    ? snapshot.playedGames.filter((gameKey) => gameKey !== key)
    : [...snapshot.playedGames, key]

  if (!isPlayed) {
    return { ...snapshot, playedGames }
  }

  const gameScores = { ...snapshot.gameScores }
  delete gameScores[key as GameKey]
  return { ...snapshot, playedGames, gameScores }
}

/** Idempotent set — retry-safe. `nextPlayed` is absolute intent, not toggle. */
export function setPlayedInSnapshot(snapshot: CloudSnapshot, key: string, nextPlayed: boolean): CloudSnapshot {
  const isPlayed = snapshot.playedGames.includes(key)
  if (nextPlayed === isPlayed) return snapshot
  if (nextPlayed) {
    return { ...snapshot, playedGames: [...snapshot.playedGames, key] }
  }
  const playedGames = snapshot.playedGames.filter((k) => k !== key)
  const gameScores = { ...snapshot.gameScores }
  delete gameScores[key as GameKey]
  return { ...snapshot, playedGames, gameScores }
}

export function setScoreInSnapshot(
  snapshot: CloudSnapshot,
  key: string,
  a: number,
  b: number,
): CloudSnapshot {
  const err = validateScore(a, b)
  if (err !== null) throw new Error(err)

  // Validate that the key corresponds to an actual schedule slot
  const validKeys = new Set(snapshot.schedule.map(s => `${s.slot}-${s.court}`))
  if (!validKeys.has(key)) throw new Error(`Invalid game key: ${key}`)

  const playedGames = snapshot.playedGames.includes(key)
    ? snapshot.playedGames
    : [...snapshot.playedGames, key]

  return {
    ...snapshot,
    playedGames,
    gameScores: {
      ...snapshot.gameScores,
      [key]: { a, b },
    },
  }
}

export function swapPlayersInSnapshot(
  snapshot: CloudSnapshot,
  t1: SwapTarget,
  t2: SwapTarget,
): CloudSnapshot {
  return {
    ...snapshot,
    schedule: applySwap(snapshot.schedule, t1, t2),
  }
}

export function swapTeamsInSnapshot(
  snapshot: CloudSnapshot,
  t1: TeamSwapTarget,
  t2: TeamSwapTarget,
): CloudSnapshot {
  return {
    ...snapshot,
    schedule: applyTeamSwap(snapshot.schedule, t1, t2),
  }
}

export function setAbsentPlayersInSnapshot(
  snapshot: CloudSnapshot,
  nextAbsent: string[],
): CloudSnapshot {
  return {
    ...snapshot,
    absentPlayers: nextAbsent,
  }
}

export function setSkippedInSnapshot(
  snapshot: CloudSnapshot,
  key: string,
  nextSkipped: string[],
): CloudSnapshot {
  const cur = snapshot.skippedPlayers ?? {}
  const next: Record<string, string[]> = { ...cur }
  if (nextSkipped.length === 0) {
    delete next[key]
  } else {
    next[key] = [...nextSkipped]
  }
  // Also clear score/played for skipped non-empty (mirror BE clear)
  if (nextSkipped.length > 0) {
    const playedGames = snapshot.playedGames.filter((k) => k !== key)
    const gameScores = { ...snapshot.gameScores }
    delete gameScores[key as GameKey]
    return { ...snapshot, skippedPlayers: next, playedGames, gameScores }
  }
  return { ...snapshot, skippedPlayers: next }
}

/**
 * Replace player name in snapshot — ONLY updates the players array name field.
 * Does NOT update schedule slot references (teamA/teamB).
 * Use within useChangePlayer which applies schedule changes separately.
 * Do NOT use standalone — will create mismatched state.
 */
export function replacePlayerNameInSnapshot(
  snapshot: CloudSnapshot,
  playerId: string,
  newName: string,
): CloudSnapshot {
  return {
    ...snapshot,
    players: snapshot.players.map((player) =>
      player.id === playerId ? { ...player, name: newName } : player,
    ),
  }
}

export function swapSlotsInSnapshot(
  snapshot: CloudSnapshot,
  g1: SlotSwapTarget,
  g2: SlotSwapTarget,
): CloudSnapshot {
  return {
    ...snapshot,
    schedule: applySlotSwap(snapshot.schedule, g1, g2),
    playedGames: swapKeyInList(snapshot.playedGames, g1, g2),
    gameScores: swapKeys(snapshot.gameScores, g1, g2),
  }
}
