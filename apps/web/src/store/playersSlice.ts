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
      // Rename tidak mengubah hasil generate → jangan reset (hindari data loss di
      // tengah sesi). Tapi gender/tier ADALAH input generator: jadwal lama bisa
      // tidak lagi valid, jadi turunan generator di-reset hanya saat keduanya berubah.
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
      const nextPlayerCount = Math.max(4, Math.min(s.session.playerCount, nextPlayers.length))
      return {
        players: nextPlayers,
        session: { ...s.session, playerCount: nextPlayerCount },
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
