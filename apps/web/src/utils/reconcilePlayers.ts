// src/utils/reconcilePlayers.ts
// Rebuild player list from schedule — ensures every non-blank UUID has a Player entry.

import type { Player, ScheduleSlot, PlayerId } from '../types'
import { toPlayerId } from '../types'

export function rebuildPlayersFromSchedule(
  schedule: ScheduleSlot[],
  existingPlayers: Player[],
  newName?: string,
  playerName?: string,
): Player[] {
  const scheduleIds = new Set<PlayerId>()
  for (const g of schedule) {
    for (const id of [...g.teamA, ...g.teamB]) {
      if (id.trim()) scheduleIds.add(id)
    }
  }
  const byId = new Map(existingPlayers.map(p => [p.id, p]))
  if (newName?.trim() && !byId.has(toPlayerId(newName))) {
    byId.set(toPlayerId(newName), { id: toPlayerId(newName), name: playerName ?? newName, gender: 'M' as const, tier: 1 as const })
  }
  const seen = new Set<PlayerId>()
  return [...scheduleIds]
    .map(id => byId.get(id) ?? { id, name: id, gender: 'M' as const, tier: 1 as const })
    .filter(p => { if (seen.has(p.id)) return false; seen.add(p.id); return true })
}
