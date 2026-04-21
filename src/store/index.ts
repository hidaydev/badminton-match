import { create } from 'zustand'
import { persist } from 'zustand/middleware'
import type { GeneratorResult } from '../generator'

export const PLAYERS_PER_GAME = 4

export type Gender = 'M' | 'F'
export type Tier = 1 | 2 | 3

export interface Player {
  id: string
  name: string
  gender: Gender
  tier: Tier
}

export interface FixMatch {
  id: string
  slots: [string, string, string, string] // '' = any
}

export interface ScheduleSlot {
  slot: number   // time slot index (0-based)
  court: number  // court index (0-based)
  teamA: [string, string]
  teamB: [string, string]
}

export interface SessionConfig {
  courts: number
  slotsPerCourt: number[]
  courtOffsets: number[]
  playerCount: number
  totalGames: number
  locked: boolean
}

interface AppState {
  session: SessionConfig
  players: Player[]
  fixMatches: FixMatch[]
  schedule: ScheduleSlot[]
  lastResult: GeneratorResult | null

  setCourts: (n: number) => void
  setCourtSlots: (courtIndex: number, slots: number) => void
  setCourtOffset: (courtIndex: number, offset: number) => void
  setPlayerCount: (n: number) => void
  lockSession: () => void
  resetSession: () => void

  addPlayer: (player: Omit<Player, 'id'>) => void
  addPlayers: (players: Omit<Player, 'id'>[]) => void
  updatePlayer: (id: string, patch: Partial<Omit<Player, 'id'>>) => void
  removePlayer: (id: string) => void

  addFixMatch: (m: Omit<FixMatch, 'id'>) => void
  updateFixMatch: (id: string, slots: FixMatch['slots']) => void
  duplicateFixMatch: (id: string) => void
  removeFixMatch: (id: string) => void

  setResult: (r: GeneratorResult) => void
}

const DEFAULT_SLOTS = 6

const defaultSession: SessionConfig = {
  courts: 2,
  slotsPerCourt: [DEFAULT_SLOTS, DEFAULT_SLOTS],
  courtOffsets: [0, 0],
  playerCount: 8,
  totalGames: DEFAULT_SLOTS * 2,
  locked: false,
}

function nanoid() {
  return Math.random().toString(36).slice(2, 9)
}

export const useStore = create<AppState>()(
  persist(
    (set) => ({
      session: defaultSession,
      players: [],
      fixMatches: [],
      schedule: [], lastResult: null,

      setCourts: (n) =>
        set((s) => {
          const prev = s.session.slotsPerCourt
          const prevOffsets = s.session.courtOffsets
          const next = Array.from({ length: n }, (_, i) => prev[i] ?? DEFAULT_SLOTS)
          const nextOffsets = Array.from({ length: n }, (_, i) => prevOffsets[i] ?? 0)
          return {
            session: {
              ...s.session,
              courts: n,
              slotsPerCourt: next,
              courtOffsets: nextOffsets,
              totalGames: next.reduce((a, b) => a + b, 0),
            },
          }
        }),

      setCourtSlots: (courtIndex, slots) =>
        set((s) => {
          const next = [...s.session.slotsPerCourt]
          next[courtIndex] = slots
          return {
            session: {
              ...s.session,
              slotsPerCourt: next,
              totalGames: next.reduce((a, b) => a + b, 0),
            },
          }
        }),

      setCourtOffset: (courtIndex, offset) =>
        set((s) => {
          const next = [...s.session.courtOffsets]
          next[courtIndex] = offset
          return { session: { ...s.session, courtOffsets: next } }
        }),

      setPlayerCount: (n) =>
        set((s) => ({ session: { ...s.session, playerCount: n } })),

      lockSession: () =>
        set((s) => ({ session: { ...s.session, locked: true } })),

      resetSession: () =>
        set({ session: defaultSession, players: [], fixMatches: [], schedule: [], lastResult: null  }),

      addPlayer: (p) =>
        set((s) => ({ players: [...s.players, { ...p, id: nanoid() }], schedule: [], lastResult: null })),

      addPlayers: (newPlayers) =>
        set((s) => ({
          players: [
            ...s.players,
            ...newPlayers.map((p) => ({ ...p, id: nanoid() })),
          ],
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
            slots: m.slots.map((s) => (s === id ? '' : s)) as FixMatch['slots'],
          })),
          schedule: [], lastResult: null,
        })),

      addFixMatch: (m) =>
        set((s) => ({ fixMatches: [...s.fixMatches, { ...m, id: nanoid() }], schedule: [], lastResult: null })),

      updateFixMatch: (id, slots) =>
        set((s) => ({
          fixMatches: s.fixMatches.map((m) => (m.id === id ? { ...m, slots } : m)),
          schedule: [], lastResult: null,
        })),

      duplicateFixMatch: (id) =>
        set((s) => {
          const idx = s.fixMatches.findIndex((m) => m.id === id)
          if (idx === -1) return s
          const copy = { ...s.fixMatches[idx], id: nanoid() }
          const next = [...s.fixMatches]
          next.splice(idx + 1, 0, copy)
          return { fixMatches: next, schedule: [], lastResult: null }
        }),

      removeFixMatch: (id) =>
        set((s) => ({ fixMatches: s.fixMatches.filter((m) => m.id !== id), schedule: [], lastResult: null })),

      setResult: (r) => set({ schedule: r.schedule, lastResult: r }),
    }),
    {
      name: 'badminton-store',
      version: 4,
      migrate: () => ({
        session: defaultSession,
        players: [],
        fixMatches: [],
        schedule: [], lastResult: null,
      }),
    }
  )
)
