import type { ScheduleSlot, GameScore, GameKey, SetScore } from '../types'
import type { GeneratorResult } from '../generator'
import type { SetState } from './index'
import { applySlotSwap, swapKeys, swapKeyInList, type SlotSwapTarget } from '../utils/slotSwap'
import { matchComplete, totalPoints, validateSets } from '../utils/scoring'

export interface ScheduleSlice {
  schedule: ScheduleSlot[]
  lastResult: GeneratorResult | null
  playedGames: string[]
  gameScores: Record<GameKey, GameScore>

  setResult: (r: GeneratorResult) => void
  updateSchedule: (schedule: ScheduleSlot[]) => void
  swapSlotsWithScores: (g1: SlotSwapTarget, g2: SlotSwapTarget) => void
  togglePlayedGame: (key: string) => void
  setGameScore: (key: string, sets: SetScore[]) => void
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

  setGameScore: (key, sets) => {
    set((s) => {
      const next = { ...s.gameScores }
      if (sets.length === 0) {
        delete next[key as GameKey]
        return {
          gameScores: next,
          playedGames: s.playedGames.filter((k) => k !== key),
        }
      }
      const rules = s.session.scoring
      if (rules && validateSets(rules, sets).error !== null) return {} // Reject invalid sets
      const totals = totalPoints(sets)
      const complete = rules ? matchComplete(rules, sets) : true
      return {
        playedGames: complete
          ? s.playedGames.includes(key) ? s.playedGames : [...s.playedGames, key]
          : s.playedGames.filter((k) => k !== key),
        gameScores: { ...next, [key]: { a: totals.a, b: totals.b, sets } } as Record<GameKey, GameScore>,
      }
    })
  },

  clearGameScore: (key) =>
    set((s) => {
      const next = { ...s.gameScores }
      delete next[key as GameKey]
      return { gameScores: next }
    }),
})
