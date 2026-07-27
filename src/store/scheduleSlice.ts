import type { ScheduleSlot, GameScore } from '../types'
import { toGameKey } from '../types'
import type { GeneratorResult } from '../generator'
import type { SetState } from './index'
import { applySlotSwap, type SlotSwapTarget } from '../utils/slotSwap'
import { validateScore } from '../utils/scoreValidation'

export interface ScheduleSlice {
  schedule: ScheduleSlot[]
  lastResult: GeneratorResult | null
  playedGames: string[]
  gameScores: Record<string, GameScore>

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
    const k1 = toGameKey(g1.slot, g1.court)
    const k2 = toGameKey(g2.slot, g2.court)

    // Migrate gameScores keys
    const gameScores: Record<string, GameScore> = {}
    for (const [key, value] of Object.entries(s.gameScores)) {
      if (key === k1) gameScores[k2] = value
      else if (key === k2) gameScores[k1] = value
      else gameScores[key] = value
    }

    // Migrate playedGames keys
    const playedGames = s.playedGames.map((key) => {
      if (key === k1) return k2
      if (key === k2) return k1
      return key
    })

    return {
      schedule,
      playedGames,
      gameScores,
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
      delete gameScores[key]
      return { playedGames, gameScores }
    }),

  setGameScore: (key, a, b) => {
    if (validateScore(a, b) !== null) return // Reject invalid scores
    set((s) => ({
      playedGames: s.playedGames.includes(key)
        ? s.playedGames
        : [...s.playedGames, key],
      gameScores: { ...s.gameScores, [key]: { a, b } },
    }))
  },

  clearGameScore: (key) =>
    set((s) => {
      const next = { ...s.gameScores }
      delete next[key]
      return { gameScores: next }
    }),
})
