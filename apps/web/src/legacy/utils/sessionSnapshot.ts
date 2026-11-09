import type { CloudSnapshot, MatchConstraint, Player, ScheduleSlot, SessionConfig, GameKey, SetScore } from '../types'
import { applySwap, applyTeamSwap, type SwapTarget, type TeamSwapTarget } from './swap.ts'
import { applySlotSwap, swapKeys, swapKeyInList, type SlotSwapTarget } from './slotSwap.ts'
import { matchComplete, totalPoints } from './scoring.ts'

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

export function setScoreSetsInSnapshot(
  snapshot: CloudSnapshot,
  key: string,
  sets: SetScore[],
): CloudSnapshot {
  const validKeys = new Set(snapshot.schedule.map(s => `${s.slot}-${s.court}`))
  if (!validKeys.has(key)) throw new Error(`Invalid game key: ${key}`)

  const gameScores = { ...snapshot.gameScores }
  if (sets.length === 0) {
    delete gameScores[key as GameKey]
    return {
      ...snapshot,
      playedGames: snapshot.playedGames.filter((k) => k !== key),
      gameScores,
    }
  }

  const totals = totalPoints(sets)
  const rules = snapshot.session.scoring
  const complete = rules ? matchComplete(rules, sets) : true
  const playedGames = complete && !snapshot.playedGames.includes(key)
    ? [...snapshot.playedGames, key]
    : !complete
      ? snapshot.playedGames.filter((k) => k !== key)
      : snapshot.playedGames

  return {
    ...snapshot,
    playedGames,
    gameScores: {
      ...gameScores,
      [key]: { a: totals.a, b: totals.b, sets },
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
    // The key is "slot-court", so it follows the schedule; otherwise the skip
    // marker would stay on the old slot until the refetch.
    ...(snapshot.skippedPlayers
      ? { skippedPlayers: swapKeys(snapshot.skippedPlayers, g1, g2) }
      : {}),
  }
}
