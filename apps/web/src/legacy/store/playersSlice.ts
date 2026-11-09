import type { Player, MatchConstraint } from '../types'
import { toPlayerId } from '../types'
import { generateId } from './sessionSlice'
import type { SetState } from './index'
import { RESET_GENERATED } from './reset'

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
    set((s) => {
      if (s.players.length >= s.session.playerCount || s.players.length >= 60) return s
      return { players: [...s.players, { ...p, id: toPlayerId(generateId()) }], ...RESET_GENERATED }
    }),

  addPlayers: (newPlayers) =>
    set((s) => {
      const cap = Math.min(s.session.playerCount, 60)
      const available = Math.max(0, cap - s.players.length)
      const toAdd = newPlayers.slice(0, available)
      if (toAdd.length === 0) return s
      return {
        players: [...s.players, ...toAdd.map((p) => ({ ...p, id: toPlayerId(generateId()) }))],
        ...RESET_GENERATED,
      }
    }),

  updatePlayer: (id, patch) =>
    set((s) => {
      const players = s.players.map((p) => (p.id === id ? { ...p, ...patch } : p))
      const current = s.players.find((p) => p.id === id)
      // A rename does not change the generated result, so do not reset (it would
      // lose data mid-session). Gender and tier ARE generator inputs though: the
      // old schedule may no longer be valid, so the generator output is reset
      // only when one of those two changes.
      const changesGeneratorInput =
        current != null &&
        ((patch.gender !== undefined && patch.gender !== current.gender) ||
          (patch.tier !== undefined && patch.tier !== current.tier))
      if (!changesGeneratorInput) return { players }
      return { players, ...RESET_GENERATED }
    }),

  removePlayer: (id) =>
    set((s) => {
      const nextPlayers = s.players.filter((p) => p.id !== id)
      // playerCount is NOT derived. It is the target set in Setup and drives the
      // "Add Player" button (disabled while players.length >= playerCount). The
      // value used to be clamped to the player count, so a single removal locked
      // the add button and players could not be restored.
      return {
        players: nextPlayers,
        fixMatches: s.fixMatches
          .map((m) => ({
            ...m,
            slots: m.slots.map((st) => (st === id ? '' : st)) as MatchConstraint['slots'],
          }))
          .filter((m) => m.slots.some((st) => st !== '')),
        absentPlayers: s.absentPlayers.filter((pid) => pid !== id),
        ...RESET_GENERATED,
      }
    }),
})
