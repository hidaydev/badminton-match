import { create } from 'zustand'
import { persist } from 'zustand/middleware'
import type { GeneratorResult } from '../generator'

export const PLAYERS_PER_GAME = 4

export type Gender = 'M' | 'F'
export type Tier = 1 | 2 | 3 | 4

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
  slot: number   // absolute time slot index
  court: number
  teamA: [string, string]
  teamB: [string, string]
}

export interface GameScore {
  a: number  // Team A score
  b: number  // Team B score
}

export interface CourtTime {
  start: string  // "09:00"
  end: string    // "11:00"
}

export interface SessionConfig {
  courts: number
  sessionStart: string    // "09:00"
  slotMinutes: number     // minutes per game slot
  courtTimes: CourtTime[]
  playerCount: number
  slotsPerCourt: number[] // derived
  totalGames: number      // derived
  courtNames: string[]
  tierCount: 3 | 4
  locked: boolean
}

interface AppState {
  sessionId: string
  session: SessionConfig
  players: Player[]
  fixMatches: FixMatch[]
  schedule: ScheduleSlot[]
  lastResult: GeneratorResult | null
  playedGames: string[]
  gameScores: Record<string, GameScore>
  cloudSessionId: string | null
  setCloudSessionId: (id: string) => void

  setCourts: (n: number) => void
  setSessionStart: (time: string) => void
  setSlotMinutes: (min: number) => void
  setCourtTime: (index: number, start: string, end: string) => void
  setPlayerCount: (n: number) => void
  setCourtName: (index: number, name: string) => void
  setTierCount: (n: 3 | 4) => void
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

  summaryOpen: boolean
  setResult: (r: GeneratorResult) => void
  togglePlayedGame: (key: string) => void
  setGameScore: (key: string, a: number, b: number) => void
  clearGameScore: (key: string) => void
  setSummaryOpen: (open: boolean) => void
}

export function timeToMinutes(t: string): number {
  const [h, m] = t.split(':').map(Number)
  return h * 60 + (m || 0)
}

export function minutesToTime(m: number): string {
  return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`
}

function derivedFromCourtTimes(courtTimes: CourtTime[], slotMinutes: number) {
  const slotsPerCourt = courtTimes.map((ct) =>
    Math.max(0, Math.floor((timeToMinutes(ct.end) - timeToMinutes(ct.start)) / slotMinutes))
  )
  return { slotsPerCourt, totalGames: slotsPerCourt.reduce((a, b) => a + b, 0) }
}

const DEFAULT_SLOT_MINUTES = 20
const DEFAULT_COURT_TIMES: CourtTime[] = [
  { start: '09:00', end: '11:00' },
  { start: '09:00', end: '11:00' },
]

const defaultSession: SessionConfig = {
  courts: 2,
  sessionStart: '09:00',
  slotMinutes: DEFAULT_SLOT_MINUTES,
  courtTimes: DEFAULT_COURT_TIMES,
  playerCount: 8,
  ...derivedFromCourtTimes(DEFAULT_COURT_TIMES, DEFAULT_SLOT_MINUTES),
  courtNames: [],
  tierCount: 3,
  locked: false,
}

function nanoid() {
  return Math.random().toString(36).slice(2, 9)
}

export const useStore = create<AppState>()(
  persist(
    (set) => ({
      sessionId: nanoid(),
      session: defaultSession,
      players: [],
      fixMatches: [],
      schedule: [], lastResult: null, playedGames: [], gameScores: {}, summaryOpen: false, cloudSessionId: null,

      setCourts: (n) =>
        set((s) => {
          const prev = s.session.courtTimes
          const courtTimes = Array.from({ length: n }, (_, i) => prev[i] ?? { start: s.session.sessionStart, end: '11:00' })
          return {
            session: {
              ...s.session,
              courts: n,
              courtTimes,
              ...derivedFromCourtTimes(courtTimes, s.session.slotMinutes),
            },
          }
        }),

      setSessionStart: (time) =>
        set((s) => {
          const courtTimes = s.session.courtTimes.map((ct) => ({
            start: timeToMinutes(ct.start) < timeToMinutes(time) ? time : ct.start,
            end: timeToMinutes(ct.end) <= timeToMinutes(time)
              ? minutesToTime(timeToMinutes(time) + s.session.slotMinutes)
              : ct.end,
          }))
          return {
            session: {
              ...s.session,
              sessionStart: time,
              courtTimes,
              ...derivedFromCourtTimes(courtTimes, s.session.slotMinutes),
            },
          }
        }),

      setSlotMinutes: (min) =>
        set((s) => ({
          session: {
            ...s.session,
            slotMinutes: min,
            ...derivedFromCourtTimes(s.session.courtTimes, min),
          },
        })),

      setCourtTime: (index, start, end) =>
        set((s) => {
          const courtTimes = [...s.session.courtTimes]
          courtTimes[index] = { start, end }
          return {
            session: {
              ...s.session,
              courtTimes,
              ...derivedFromCourtTimes(courtTimes, s.session.slotMinutes),
            },
          }
        }),

      setPlayerCount: (n) =>
        set((s) => ({ session: { ...s.session, playerCount: n } })),

      setCourtName: (index, name) =>
        set((s) => {
          const courtNames = [...s.session.courtNames]
          courtNames[index] = name
          return { session: { ...s.session, courtNames } }
        }),

      setTierCount: (n) =>
        set((s) => ({ session: { ...s.session, tierCount: n } })),

      lockSession: () =>
        set((s) => ({ session: { ...s.session, locked: true } })),

      resetSession: () =>
        set({ sessionId: nanoid(), session: defaultSession, players: [], fixMatches: [], schedule: [], lastResult: null, playedGames: [], gameScores: {}, summaryOpen: false, cloudSessionId: null }),

      addPlayer: (p) =>
        set((s) => ({ players: [...s.players, { ...p, id: nanoid() }], schedule: [], lastResult: null })),

      addPlayers: (newPlayers) =>
        set((s) => ({
          players: [...s.players, ...newPlayers.map((p) => ({ ...p, id: nanoid() }))],
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

      setResult: (r) => set({ schedule: r.schedule, lastResult: r, playedGames: [], gameScores: {} }),

      togglePlayedGame: (key) =>
        set((s) => ({
          playedGames: s.playedGames.includes(key)
            ? s.playedGames.filter((k) => k !== key)
            : [...s.playedGames, key],
        })),

      setGameScore: (key, a, b) =>
        set((s) => ({ gameScores: { ...s.gameScores, [key]: { a, b } } })),

      clearGameScore: (key) =>
        set((s) => {
          const next = { ...s.gameScores }
          delete next[key]
          return { gameScores: next }
        }),

      setSummaryOpen: (open) => set({ summaryOpen: open }),

      setCloudSessionId: (id) => set({ cloudSessionId: id }),
    }),
    {
      name: 'badminton-store',
      version: 11,
      migrate: () => ({
        sessionId: nanoid(),
        session: defaultSession,
        players: [],
        fixMatches: [],
        schedule: [], lastResult: null, playedGames: [], gameScores: {}, summaryOpen: false, cloudSessionId: null,
      }),
    }
  )
)
