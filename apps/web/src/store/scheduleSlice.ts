import type { ScheduleSlot, GameScore, GameKey } from '../types'
import type { GeneratorResult } from '../generator'
import type { SetState } from './index'
import { applySlotSwap, swapKeys, swapKeyInList, type SlotSwapTarget } from '../utils/slotSwap'
import { validateScore } from '../utils/scoreValidation'

export interface ScheduleSlice {
  schedule: ScheduleSlot[]
  lastResult: GeneratorResult | null
  playedGames: string[]
  gameScores: Record<GameKey, GameScore>

  setResult: (r: GeneratorResult) => void
  updateSchedule: (schedule: ScheduleSlot[]) => void
  swapSlotsWithScores: (g1: SlotSwapTarget, g2: SlotSwapTarget) => void
  togglePlayedGame: (key: string) => void
  setGameScore: (key: string, a: number, b: number) => void
  clearGameScore: (key: string) => void
}

export const createScheduleSlice = (
  set: SetState
): ScheduleSlice => ({
  schedule: [],
  lastResult: null,
  playedGames: [],
  gameScores: {},

  setResult: (r) => set(() => ({ schedule: r.schedule, lastResult: r, playedGames: [], gameScores: {} })),

  updateSchedule: (schedule) => set((s) => ({
    schedule,
    lastResult: s.lastResult ? { ...s.lastResult, schedule } : null,
  })),

  swapSlotsWithScores: (g1, g2) => set((s) => {
    const schedule = applySlotSwap(s.schedule, g1, g2)
    return {
      schedule,
      playedGames: swapKeyInList(s.playedGames, g1, g2),
      gameScores: swapKeys(s.gameScores, g1, g2) as Record<GameKey, GameScore>,
      lastResult: s.lastResult ? { ...s.lastResult, schedule } : null,
    }
  }),

  togglePlayedGame: (key) =>
    set((s) => {
      const isPlayed = s.playedGames.includes(key)
      const playedGames = isPlayed
        ? s.playedGames.filter((k) => k !== key)
        : [...s.playedGames, key]

      if (!isPlayed) return { playedGames }

      const gameScores = { ...s.gameScores }
      delete gameScores[key as GameKey]
      return { playedGames, gameScores }
    }),

  setGameScore: (key, a, b) => {
    if (validateScore(a, b) !== null) return // Reject invalid scores
    set((s) => ({
      playedGames: s.playedGames.includes(key)
        ? s.playedGames
        : [...s.playedGames, key],
      gameScores: { ...s.gameScores, [key]: { a, b } } as Record<GameKey, GameScore>,
    }))
  },

  clearGameScore: (key) =>
    set((s) => {
      const next = { ...s.gameScores }
      delete next[key as GameKey]
      return { gameScores: next }
    }),
})
