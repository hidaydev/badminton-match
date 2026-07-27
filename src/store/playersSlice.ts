import type { Player, MatchConstraint } from '../types'
import { toPlayerId } from '../types'
import { generateId } from './sessionSlice'
import type { SetState } from './index'

export interface PlayersSlice {
  players: Player[]

  addPlayer: (player: Omit<Player, 'id'>) => void
  addPlayers: (players: Omit<Player, 'id'>[]) => void
  updatePlayer: (id: string, patch: Partial<Omit<Player, 'id'>>) => void
  removePlayer: (id: string) => void
}

export const createPlayersSlice = (
  set: SetState
): PlayersSlice => ({
  players: [],

  addPlayer: (p) =>
    set((s) => ({ players: [...s.players, { ...p, id: toPlayerId(generateId()) }], schedule: [], lastResult: null })),

  addPlayers: (newPlayers) =>
    set((s) => ({
      players: [...s.players, ...newPlayers.map((p) => ({ ...p, id: toPlayerId(generateId()) }))],
      schedule: [], lastResult: null,
    })),

  updatePlayer: (id, patch) =>
    set((s) => ({
      players: s.players.map((p) => (p.id === id ? { ...p, ...patch } : p)),
      schedule: [], lastResult: null,
    })),

  removePlayer: (id) =>
    set((s) => ({
      players: s.players.filter((p) => p.id !== id),
      fixMatches: s.fixMatches.map((m) => ({
        ...m,
        slots: m.slots.map((s) => (s === id ? '' : s)) as MatchConstraint['slots'],
      })),
      absentPlayers: s.absentPlayers.filter((pid) => pid !== id),
      schedule: [], lastResult: null,
    })),
})
