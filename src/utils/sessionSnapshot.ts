import type { CloudSnapshot } from '../queries/types.ts'
import { applySwap, applyTeamSwap, applyChange, type SwapTarget, type TeamSwapTarget, type ChangeTarget } from './swap.ts'
import { applySlotSwap, type SlotSwapTarget } from './slotSwap.ts'
import type { FixMatch, Player, ScheduleSlot, SessionConfig } from '../store/index.ts'

interface PublishableSessionInput {
  version?: number
  existingAbsentPlayers?: string[]
  session: SessionConfig
  players: Player[]
  fixMatches: FixMatch[]
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
  delete gameScores[key]
  return { ...snapshot, playedGames, gameScores }
}

export function setScoreInSnapshot(
  snapshot: CloudSnapshot,
  key: string,
  a: number,
  b: number,
): CloudSnapshot {
  // Reject equal scores (including 0-0)
  if (a === b) return snapshot

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

function migrateKeys<T>(
  record: Record<string, T>,
  g1: SlotSwapTarget,
  g2: SlotSwapTarget,
): Record<string, T> {
  const k1 = `${g1.slot}-${g1.court}`
  const k2 = `${g2.slot}-${g2.court}`
  const next: Record<string, T> = {}
  for (const [key, value] of Object.entries(record)) {
    if (key === k1) next[k2] = value
    else if (key === k2) next[k1] = value
    else next[key] = value
  }
  return next
}

function migratePlayedGames(
  playedGames: string[],
  g1: SlotSwapTarget,
  g2: SlotSwapTarget,
): string[] {
  const k1 = `${g1.slot}-${g1.court}`
  const k2 = `${g2.slot}-${g2.court}`
  return playedGames.map((key) => {
    if (key === k1) return k2
    if (key === k2) return k1
    return key
  })
}

export function swapSlotsInSnapshot(
  snapshot: CloudSnapshot,
  g1: SlotSwapTarget,
  g2: SlotSwapTarget,
): CloudSnapshot {
  return {
    ...snapshot,
    schedule: applySlotSwap(snapshot.schedule, g1, g2),
    playedGames: migratePlayedGames(snapshot.playedGames, g1, g2),
    gameScores: migrateKeys(snapshot.gameScores, g1, g2),
  }
}

export function changePlayerInSnapshot(
  snapshot: CloudSnapshot,
  target: ChangeTarget,
  replacementPlayerId: string,
): CloudSnapshot {
  return {
    ...snapshot,
    schedule: applyChange(snapshot.schedule, target, replacementPlayerId),
  }
}
